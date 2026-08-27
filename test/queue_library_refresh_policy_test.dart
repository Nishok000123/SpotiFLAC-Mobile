import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:spotiflac_android/screens/queue_library_refresh_policy.dart';
import 'package:spotiflac_android/services/library_database.dart';

void main() {
  const empty = QueueLibraryCounts(
    allTrackCount: 0,
    albumCount: 0,
    singleTrackCount: 0,
  );
  const cached = QueueLibraryCounts(
    allTrackCount: 20,
    albumCount: 2,
    singleTrackCount: 3,
  );
  const fallback = QueueLibraryCounts(
    allTrackCount: 15,
    albumCount: 1,
    singleTrackCount: 4,
  );

  test('keeps cached counts when a download refresh returns empty', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      cached: cached,
      activeDownloadFallback: fallback,
    );

    expect(identical(resolved, cached), isTrue);
  });

  test('uses in-memory history when no page cache exists yet', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      activeDownloadFallback: fallback,
    );

    expect(identical(resolved, fallback), isTrue);
  });

  test('allows a legitimate empty refresh without an active fallback', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      cached: cached,
    );

    expect(identical(resolved, empty), isTrue);
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: true,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: false,
      ),
      isFalse,
    );
  });

  test('retains a non-empty page only while its fallback is available', () {
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: true,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: true,
      ),
      isTrue,
    );
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: false,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: true,
      ),
      isFalse,
    );
  });

  test('completion bridge prefers distinct finalized path candidates', () {
    expect(
      resolveCompletionBridgePlayableCandidates(
        historyFilePath: ' /music/final.flac ',
        completedItemFilePath: '/music/completed.flac',
      ),
      ['/music/final.flac', '/music/completed.flac'],
    );
    expect(
      resolveCompletionBridgePlayableCandidates(
        historyFilePath: ' /music/final.flac ',
        completedItemFilePath: '/music/final.flac',
      ),
      ['/music/final.flac'],
    );
    expect(
      resolveCompletionBridgePlayablePath(
        historyFilePath: ' ',
        completedItemFilePath: ' /music/completed.flac ',
      ),
      '/music/completed.flac',
    );
    expect(
      resolveCompletionBridgePlayablePath(
        historyFilePath: null,
        completedItemFilePath: '',
      ),
      isNull,
    );
  });

  test(
    'completion probe falls back from stale history to completed path',
    () async {
      final checkedPaths = <String>[];
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (path) async {
          checkedPaths.add(path);
          return path == '/music/completed.flac';
        },
        retryDelays: const [],
      );
      addTearDown(probe.dispose);

      final result = probe.listenable(
        historyFilePath: '/music/stale.flac',
        completedItemFilePath: '/music/completed.flac',
      );
      expect(result.value.status, CompletionBridgePlayableStatus.checking);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(checkedPaths, ['/music/stale.flac', '/music/completed.flac']);
      expect(result.value.status, CompletionBridgePlayableStatus.playable);
      expect(result.value.path, '/music/completed.flac');
    },
  );

  test(
    'completion probe retries publication before reporting missing',
    () async {
      var checks = 0;
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (_) async => ++checks >= 3,
        retryDelays: const [Duration.zero, Duration.zero],
      );
      addTearDown(probe.dispose);

      final result = probe.listenable(
        completedItemFilePath: 'content://downloads/final.flac',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(checks, 3);
      expect(result.value.status, CompletionBridgePlayableStatus.playable);
      expect(result.value.path, 'content://downloads/final.flac');
    },
  );

  test('completion probe can refresh a cached missing destination', () async {
    var exists = false;
    final probe = CompletionBridgePlayableProbeCache(
      pathExists: (_) async => exists,
      retryDelays: const [],
    );
    addTearDown(probe.dispose);

    final result = probe.listenable(
      completedItemFilePath: '/music/reused.flac',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(result.value.status, CompletionBridgePlayableStatus.missing);

    exists = true;
    probe.refreshForPath('/music/reused.flac');
    expect(result.value.status, CompletionBridgePlayableStatus.checking);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(result.value.status, CompletionBridgePlayableStatus.playable);
    expect(result.value.path, '/music/reused.flac');
  });

  test(
    'completion probe does not evict an actively listened notifier',
    () async {
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (_) async => true,
        retryDelays: const [],
        maxEntries: 2,
      );
      addTearDown(probe.dispose);

      final first = probe.listenable(
        completedItemFilePath: '/music/first.flac',
      );
      void listener() {}

      first.addListener(listener);
      final second = probe.listenable(
        completedItemFilePath: '/music/second.flac',
      );
      probe.listenable(completedItemFilePath: '/music/third.flac');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        identical(
          first,
          probe.listenable(completedItemFilePath: '/music/first.flac'),
        ),
        isTrue,
      );
      expect(
        identical(
          second,
          probe.listenable(completedItemFilePath: '/music/second.flac'),
        ),
        isFalse,
      );
      expect(() => first.removeListener(listener), returnsNormally);
    },
  );

  test('completion bridge cards probe before showing Play or missing', () {
    final source = File(
      'lib/screens/queue_tab_collection_items.dart',
    ).readAsStringSync();
    final gridStart = source.indexOf('Widget _buildBridgeGridItem(');
    final listStart = source.indexOf('Widget _buildBridgeListItem(');
    final badgeStart = source.indexOf('Widget _buildLibraryQualityBadge(');

    expect(gridStart, greaterThanOrEqualTo(0));
    expect(listStart, greaterThan(gridStart));
    expect(badgeStart, greaterThan(listStart));

    final gridSource = source.substring(gridStart, listStart);
    final listSource = source.substring(listStart, badgeStart);

    expect(gridSource, contains('resolveCompletionBridgePlayablePath('));
    expect(gridSource, contains('_completionBridgePlayableProbe.listenable('));
    expect(gridSource, contains('CompletionBridgePlayableStatus.checking'));
    expect(gridSource, contains('semanticsLabel:'));
    expect(gridSource, contains('queueCheckingDownloadedFile'));
    expect(gridSource, contains('TrackGridPlayButton('));
    expect(listSource, contains('resolveCompletionBridgePlayablePath('));
    expect(listSource, contains('_completionBridgePlayableProbe.listenable('));
    expect(listSource, contains('CompletionBridgePlayableStatus.checking'));
    expect(listSource, contains('semanticsLabel:'));
    expect(listSource, contains('queueCheckingDownloadedFile'));
    expect(listSource, contains('Icons.play_arrow'));
  });
}
