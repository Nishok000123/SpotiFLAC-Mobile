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

  test('completion bridge prefers the finalized history path', () {
    expect(
      resolveCompletionBridgePlayablePath(
        historyFilePath: ' /music/final.flac ',
        completedItemFilePath: '/music/staging.flac',
      ),
      '/music/final.flac',
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

  test('completion bridge cards retain Play actions during a batch', () {
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
    expect(gridSource, contains('_fileExistsListenable(playablePath)'));
    expect(gridSource, contains('TrackGridPlayButton('));
    expect(listSource, contains('resolveCompletionBridgePlayablePath('));
    expect(listSource, contains('_fileExistsListenable(playablePath)'));
    expect(listSource, contains('Icons.play_arrow'));
  });
}
