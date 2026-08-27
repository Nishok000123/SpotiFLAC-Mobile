import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/utils/file_access.dart';

bool queueLibraryCountsHaveContent(QueueLibraryCounts counts) =>
    counts.allTrackCount > 0 ||
    counts.albumCount > 0 ||
    counts.singleTrackCount > 0;

QueueLibraryCounts resolveQueueLibraryCountsSnapshot({
  required QueueLibraryCounts current,
  QueueLibraryCounts? cached,
  QueueLibraryCounts? activeDownloadFallback,
}) {
  if (queueLibraryCountsHaveContent(current) ||
      activeDownloadFallback == null) {
    return current;
  }
  if (cached != null && queueLibraryCountsHaveContent(cached)) {
    return cached;
  }
  return activeDownloadFallback;
}

bool shouldRetainQueueLibraryPageSnapshot({
  required bool currentIsEmpty,
  required bool cachedHasContent,
  required bool activeDownloadFallbackAvailable,
}) => currentIsEmpty && cachedHasContent && activeDownloadFallbackAvailable;

/// Returns distinct final-path candidates for a just-completed download.
/// History is authoritative after conversion/SAF publication, while the
/// completed queue item remains a safe fallback if the matched history row is
/// stale or has not been adopted into the in-memory index yet.
List<String> resolveCompletionBridgePlayableCandidates({
  String? historyFilePath,
  String? completedItemFilePath,
}) {
  final candidates = <String>[];
  for (final rawPath in [historyFilePath, completedItemFilePath]) {
    final path = rawPath?.trim();
    if (path != null && path.isNotEmpty && !candidates.contains(path)) {
      candidates.add(path);
    }
  }
  return candidates;
}

/// Synchronous preferred candidate retained for non-probing callers.
String? resolveCompletionBridgePlayablePath({
  String? historyFilePath,
  String? completedItemFilePath,
}) {
  final candidates = resolveCompletionBridgePlayableCandidates(
    historyFilePath: historyFilePath,
    completedItemFilePath: completedItemFilePath,
  );
  return candidates.isEmpty ? null : candidates.first;
}

enum CompletionBridgePlayableStatus { checking, playable, missing }

@immutable
class CompletionBridgePlayableResult {
  final CompletionBridgePlayableStatus status;
  final String? path;

  const CompletionBridgePlayableResult._(this.status, this.path);

  const CompletionBridgePlayableResult.checking()
    : this._(CompletionBridgePlayableStatus.checking, null);

  const CompletionBridgePlayableResult.playable(String path)
    : this._(CompletionBridgePlayableStatus.playable, path);

  const CompletionBridgePlayableResult.missing()
    : this._(CompletionBridgePlayableStatus.missing, null);
}

typedef CompletionBridgePathExists = Future<bool> Function(String path);

/// Probes both completion-path candidates and keeps a bridge in a neutral
/// checking state while delayed SAF publication becomes visible. A definitive
/// missing result is emitted only after the retry window is exhausted.
class CompletionBridgePlayableProbeCache {
  static const int _defaultMaxEntries = 500;
  static const List<Duration> _defaultRetryDelays = [
    Duration(milliseconds: 350),
    Duration(milliseconds: 700),
    Duration(milliseconds: 1400),
    Duration(milliseconds: 2200),
  ];

  final CompletionBridgePathExists _pathExists;
  final List<Duration> _retryDelays;
  final int _maxEntries;
  final Map<String, _CompletionBridgeProbeEntry> _entries = {};
  final ValueNotifier<CompletionBridgePlayableResult> _missingNotifier =
      ValueNotifier(const CompletionBridgePlayableResult.missing());
  bool _disposed = false;

  CompletionBridgePlayableProbeCache({
    CompletionBridgePathExists pathExists = fileExists,
    List<Duration> retryDelays = _defaultRetryDelays,
    int maxEntries = _defaultMaxEntries,
  }) : assert(maxEntries > 0),
       _pathExists = pathExists,
       _retryDelays = List.unmodifiable(retryDelays),
       _maxEntries = maxEntries;

  ValueListenable<CompletionBridgePlayableResult> listenable({
    String? historyFilePath,
    String? completedItemFilePath,
  }) {
    final candidates = resolveCompletionBridgePlayableCandidates(
      historyFilePath: historyFilePath,
      completedItemFilePath: completedItemFilePath,
    );
    if (candidates.isEmpty || _disposed) return _missingNotifier;

    final key = candidates.join('\u0000');
    final existing = _entries[key];
    if (existing != null) return existing.notifier;

    while (_entries.length >= _maxEntries) {
      String? evictionKey;
      for (final candidate in _entries.entries) {
        if (!candidate.value.notifier.hasActiveListeners) {
          evictionKey = candidate.key;
          break;
        }
      }
      if (evictionKey == null) break;
      _entries.remove(evictionKey)?.dispose();
    }

    final entry = _CompletionBridgeProbeEntry(candidates);
    _entries[key] = entry;
    unawaited(_probe(entry, attempt: 0));
    return entry.notifier;
  }

  /// Rechecks cached probes that mention [filePath], including a previously
  /// missing result from an earlier completion of the same destination.
  void refreshForPath(String? filePath) {
    final path = filePath?.trim();
    if (path == null || path.isEmpty || _disposed) return;
    for (final entry in _entries.values) {
      if (!entry.candidates.contains(path)) continue;
      entry.timer?.cancel();
      entry.timer = null;
      entry.generation++;
      entry.notifier.value = const CompletionBridgePlayableResult.checking();
      unawaited(_probe(entry, attempt: 0));
    }
  }

  Future<void> _probe(
    _CompletionBridgeProbeEntry entry, {
    required int attempt,
  }) async {
    final generation = entry.generation;
    for (final path in entry.candidates) {
      var exists = false;
      try {
        exists = await _pathExists(path);
      } catch (_) {}
      if (_disposed || generation != entry.generation) return;
      if (exists) {
        entry.notifier.value = CompletionBridgePlayableResult.playable(path);
        return;
      }
    }

    if (attempt >= _retryDelays.length) {
      entry.notifier.value = const CompletionBridgePlayableResult.missing();
      return;
    }

    entry.timer = Timer(_retryDelays[attempt], () {
      entry.timer = null;
      if (_disposed || generation != entry.generation) return;
      unawaited(_probe(entry, attempt: attempt + 1));
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    _missingNotifier.dispose();
  }
}

class _CompletionBridgeProbeEntry {
  final List<String> candidates;
  final _CompletionBridgeProbeNotifier notifier =
      _CompletionBridgeProbeNotifier();
  Timer? timer;
  int generation = 0;
  bool disposed = false;

  _CompletionBridgeProbeEntry(this.candidates);

  void dispose() {
    if (disposed) return;
    disposed = true;
    generation++;
    timer?.cancel();
    notifier.dispose();
  }
}

class _CompletionBridgeProbeNotifier
    extends ValueNotifier<CompletionBridgePlayableResult> {
  _CompletionBridgeProbeNotifier()
    : super(const CompletionBridgePlayableResult.checking());

  bool get hasActiveListeners => hasListeners;
}
