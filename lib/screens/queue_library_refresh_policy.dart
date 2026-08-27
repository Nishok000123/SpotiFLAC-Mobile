import 'package:spotiflac_android/services/library_database.dart';

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

/// Resolves the playable path for a just-completed download while its pinned
/// completion-bridge card is still visible. The finalized history path wins
/// because conversion or SAF publication may change the original queue path.
String? resolveCompletionBridgePlayablePath({
  String? historyFilePath,
  String? completedItemFilePath,
}) {
  final historyPath = historyFilePath?.trim();
  if (historyPath != null && historyPath.isNotEmpty) return historyPath;

  final completedPath = completedItemFilePath?.trim();
  return completedPath == null || completedPath.isEmpty ? null : completedPath;
}
