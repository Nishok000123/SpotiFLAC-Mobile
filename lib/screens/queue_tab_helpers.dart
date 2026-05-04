part of 'queue_tab.dart';

enum LibraryItemSource { downloaded, local }

class UnifiedLibraryItem {
  final String id;
  final String trackName;
  final String artistName;
  final String albumName;
  final String? coverUrl;
  final String? localCoverPath;
  final String filePath;
  final String? quality;
  final DateTime addedAt;
  final LibraryItemSource source;

  final DownloadHistoryItem? historyItem;
  final LocalLibraryItem? localItem;

  UnifiedLibraryItem({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.coverUrl,
    this.localCoverPath,
    required this.filePath,
    this.quality,
    required this.addedAt,
    required this.source,
    this.historyItem,
    this.localItem,
  });

  factory UnifiedLibraryItem.fromDownloadHistory(DownloadHistoryItem item) {
    return UnifiedLibraryItem(
      id: 'dl_${item.id}',
      trackName: item.trackName,
      artistName: item.artistName,
      albumName: item.albumName,
      coverUrl: item.coverUrl,
      filePath: item.filePath,
      quality: buildDisplayAudioQuality(
        bitDepth: item.bitDepth,
        sampleRate: item.sampleRate,
        storedQuality: item.quality,
      ),
      addedAt: item.downloadedAt,
      source: LibraryItemSource.downloaded,
      historyItem: item,
    );
  }

  factory UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem item) {
    String? quality;
    if (item.bitrate != null && item.bitrate! > 0) {
      quality = buildDisplayAudioQuality(
        bitrateKbps: item.bitrate,
        format: item.format,
      );
    } else if (item.bitDepth != null &&
        item.bitDepth! > 0 &&
        item.sampleRate != null) {
      quality = buildDisplayAudioQuality(
        bitDepth: item.bitDepth,
        sampleRate: item.sampleRate,
      );
    }
    return UnifiedLibraryItem(
      id: 'local_${item.id}',
      trackName: item.trackName,
      artistName: item.artistName,
      albumName: item.albumName,
      coverUrl: null,
      localCoverPath: item.coverPath,
      filePath: item.filePath,
      quality: quality,
      addedAt: item.fileModTime != null
          ? DateTime.fromMillisecondsSinceEpoch(item.fileModTime!)
          : item.scannedAt,
      source: LibraryItemSource.local,
      localItem: item,
    );
  }

  bool get hasCover =>
      coverUrl != null ||
      (localCoverPath != null && localCoverPath!.isNotEmpty);

  String? get albumArtist => historyItem?.albumArtist ?? localItem?.albumArtist;

  String? get releaseDate => historyItem?.releaseDate ?? localItem?.releaseDate;

  String? get genre => historyItem?.genre ?? localItem?.genre;

  int? get trackNumber => historyItem?.trackNumber ?? localItem?.trackNumber;

  int? get discNumber => historyItem?.discNumber ?? localItem?.discNumber;

  String? get isrc => historyItem?.isrc ?? localItem?.isrc;

  String? get label => historyItem?.label ?? localItem?.label;

  String get searchKey =>
      '${trackName.toLowerCase()}|${artistName.toLowerCase()}|${albumName.toLowerCase()}';
  String get albumKey =>
      '${albumName.toLowerCase()}|${artistName.toLowerCase()}';

  /// Returns the collection key used to match this item against playlist
  /// entries. Uses the same logic as [trackCollectionKey] from the collections
  /// provider: prefer ISRC, fall back to source:id.
  String get collectionKey {
    if (historyItem != null) {
      final isrc = historyItem!.isrc?.trim();
      if (isrc != null && isrc.isNotEmpty) return 'isrc:${isrc.toUpperCase()}';
      final source = historyItem!.service.trim().isNotEmpty
          ? historyItem!.service.trim()
          : 'builtin';
      return '$source:${historyItem!.id}';
    }
    if (localItem != null) {
      final isrc = localItem!.isrc?.trim();
      if (isrc != null && isrc.isNotEmpty) return 'isrc:${isrc.toUpperCase()}';
      return 'local:${localItem!.id}';
    }
    return 'builtin:$id';
  }

  Track toTrack() {
    if (historyItem != null) {
      final h = historyItem!;
      return Track(
        id: h.id,
        name: h.trackName,
        artistName: h.artistName,
        albumName: h.albumName,
        albumArtist: h.albumArtist,
        coverUrl: h.coverUrl,
        isrc: h.isrc,
        duration: h.duration ?? 0,
        trackNumber: h.trackNumber,
        discNumber: h.discNumber,
        releaseDate: h.releaseDate,
        source: h.service,
      );
    }
    if (localItem != null) {
      final l = localItem!;
      return Track(
        id: l.id,
        name: l.trackName,
        artistName: l.artistName,
        albumName: l.albumName,
        albumArtist: l.albumArtist,
        coverUrl: l.coverPath,
        isrc: l.isrc,
        duration: l.duration ?? 0,
        trackNumber: l.trackNumber,
        discNumber: l.discNumber,
        releaseDate: l.releaseDate,
        source: 'local',
      );
    }
    return Track(
      id: id,
      name: trackName,
      artistName: artistName,
      albumName: albumName,
      coverUrl: coverUrl,
      duration: 0,
    );
  }
}

class _GroupedAlbum {
  final String albumName;
  final String artistName;
  final String? coverUrl;
  final String sampleFilePath;
  final List<DownloadHistoryItem> tracks;
  final DateTime latestDownload;
  final String searchKey;

  _GroupedAlbum({
    required this.albumName,
    required this.artistName,
    this.coverUrl,
    required this.sampleFilePath,
    required this.tracks,
    required this.latestDownload,
  }) : searchKey = '${albumName.toLowerCase()}|${artistName.toLowerCase()}';

  String get key => '$albumName|$artistName';
}

class _GroupedLocalAlbum {
  final String albumName;
  final String artistName;
  final String? coverPath;
  final List<LocalLibraryItem> tracks;
  final DateTime latestScanned;
  final String searchKey;

  _GroupedLocalAlbum({
    required this.albumName,
    required this.artistName,
    this.coverPath,
    required this.tracks,
    required this.latestScanned,
  }) : searchKey = '${albumName.toLowerCase()}|${artistName.toLowerCase()}';

  String get key => '$albumName|$artistName';
}

class _HistoryStats {
  final Map<String, int> albumCounts;
  final Map<String, int> localAlbumCounts;
  final List<_GroupedAlbum> groupedAlbums;
  final List<_GroupedLocalAlbum> groupedLocalAlbums;
  final int albumCount;
  final int singleTracks;
  final int localAlbumCount;
  final int localSingleTracks;

  const _HistoryStats({
    required this.albumCounts,
    this.localAlbumCounts = const {},
    required this.groupedAlbums,
    this.groupedLocalAlbums = const [],
    required this.albumCount,
    required this.singleTracks,
    this.localAlbumCount = 0,
    this.localSingleTracks = 0,
  });

  int get totalAlbumCount => albumCount + localAlbumCount;

  int get totalSingleTracks => singleTracks + localSingleTracks;
}

class _FilterContentData {
  final List<DownloadHistoryItem> historyItems;
  final List<UnifiedLibraryItem> unifiedItems;
  final List<UnifiedLibraryItem> filteredUnifiedItems;
  final List<_GroupedAlbum> filteredGroupedAlbums;
  final List<_GroupedLocalAlbum> filteredGroupedLocalAlbums;
  final bool showFilteringIndicator;

  const _FilterContentData({
    required this.historyItems,
    required this.unifiedItems,
    required this.filteredUnifiedItems,
    required this.filteredGroupedAlbums,
    required this.filteredGroupedLocalAlbums,
    required this.showFilteringIndicator,
  });

  int get totalTrackCount => filteredUnifiedItems.length;
  int get totalAlbumCount =>
      filteredGroupedAlbums.length + filteredGroupedLocalAlbums.length;
}

class _UnifiedCacheEntry {
  final List<DownloadHistoryItem> historyItems;
  final List<LocalLibraryItem> localItems;
  final Map<String, int> localAlbumCounts;
  final String query;
  final List<UnifiedLibraryItem> items;

  const _UnifiedCacheEntry({
    required this.historyItems,
    required this.localItems,
    required this.localAlbumCounts,
    required this.query,
    required this.items,
  });
}

class _QueueItemIdsSnapshot {
  final List<String> ids;

  const _QueueItemIdsSnapshot(this.ids);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _QueueItemIdsSnapshot && listEquals(ids, other.ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

class _QueueGroupedAlbumFilterRequest {
  final String searchQuery;
  final String? filterSource;
  final String? filterQuality;
  final String? filterFormat;
  final String? filterMetadata;
  final String sortMode;

  const _QueueGroupedAlbumFilterRequest({
    required this.searchQuery,
    required this.filterSource,
    required this.filterQuality,
    required this.filterFormat,
    required this.filterMetadata,
    required this.sortMode,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _QueueGroupedAlbumFilterRequest &&
          searchQuery == other.searchQuery &&
          filterSource == other.filterSource &&
          filterQuality == other.filterQuality &&
          filterFormat == other.filterFormat &&
          filterMetadata == other.filterMetadata &&
          sortMode == other.sortMode;

  @override
  int get hashCode => Object.hash(
    searchQuery,
    filterSource,
    filterQuality,
    filterFormat,
    filterMetadata,
    sortMode,
  );
}

class _QueueHistoryStatsMemoEntry {
  final List<DownloadHistoryItem> historyItems;
  final List<LocalLibraryItem> localItems;
  final _HistoryStats stats;

  const _QueueHistoryStatsMemoEntry({
    required this.historyItems,
    required this.localItems,
    required this.stats,
  });
}

_QueueHistoryStatsMemoEntry? _queueHistoryStatsMemo;

class _FileExistsListenableCache {
  static const int _maxCacheSize = 500;

  final Map<String, bool> _cache = {};
  final Map<String, ValueNotifier<bool>> _notifiers = {};
  final ValueNotifier<bool> _alwaysMissingNotifier = ValueNotifier(false);
  final Set<String> _pendingChecks = {};

  ValueListenable<bool> listenable(String? filePath) {
    final cleanPath = DownloadedEmbeddedCoverResolver.cleanFilePath(filePath);
    if (cleanPath.isEmpty) return _alwaysMissingNotifier;

    final existingNotifier = _notifiers[cleanPath];
    if (existingNotifier != null) {
      final cached = _cache[cleanPath];
      if (cached != null && existingNotifier.value != cached) {
        existingNotifier.value = cached;
      } else if (cached == null) {
        _startCheck(cleanPath);
      }
      return existingNotifier;
    }

    if (_notifiers.length >= _maxCacheSize) {
      final oldestKey = _notifiers.keys.first;
      _notifiers.remove(oldestKey)?.dispose();
      _cache.remove(oldestKey);
    }

    final notifier = ValueNotifier<bool>(_cache[cleanPath] ?? true);
    _notifiers[cleanPath] = notifier;
    _startCheck(cleanPath);
    return notifier;
  }

  void _startCheck(String cleanPath) {
    if (_pendingChecks.contains(cleanPath)) {
      return;
    }

    final cached = _cache[cleanPath];
    if (cached != null) {
      final notifier = _notifiers[cleanPath];
      if (notifier != null && notifier.value != cached) {
        notifier.value = cached;
      }
      return;
    }

    _pendingChecks.add(cleanPath);
    Future.microtask(() async {
      final exists = await fileExists(cleanPath);
      _pendingChecks.remove(cleanPath);
      _cache[cleanPath] = exists;
      final notifier = _notifiers[cleanPath];
      if (notifier != null && notifier.value != exists) {
        notifier.value = exists;
      }
    });
  }

  void dispose() {
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    _alwaysMissingNotifier.dispose();
  }
}

String _queueHistoryAlbumKey(String albumName, String artistName) {
  return '${albumName.toLowerCase()}|${artistName.toLowerCase()}';
}

String _queueFileExtLower(String filePath) {
  final slashIndex = filePath.lastIndexOf('/');
  final dotIndex = filePath.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex < slashIndex + 1) {
    return '';
  }
  return filePath.substring(dotIndex + 1).toLowerCase();
}

bool _queueHasMetadataValue(String? value) {
  return value != null && value.trim().isNotEmpty;
}

String _queueNormalizedMetadataValue(String? value) {
  return value?.trim().toLowerCase() ?? '';
}

DateTime? _queueParseReleaseDate(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) {
    return null;
  }

  final parsed = DateTime.tryParse(trimmed);
  if (parsed != null) {
    return parsed;
  }

  final yearMatch = RegExp(r'(\d{4})').firstMatch(trimmed);
  if (yearMatch == null) {
    return null;
  }

  final year = int.tryParse(yearMatch.group(1)!);
  if (year == null || year <= 0) {
    return null;
  }
  return DateTime(year);
}

bool _queueMatchesMetadataFilter({
  required String? filterMetadata,
  required String? artistName,
  required String? albumArtist,
  required String? releaseDate,
  required String? genre,
  required int? trackNumber,
  required int? discNumber,
  required String? isrc,
  required String? label,
}) {
  if (filterMetadata == null) {
    return true;
  }

  final hasArtist = _queueHasMetadataValue(artistName);
  final hasAlbumArtist = _queueHasMetadataValue(albumArtist);
  final hasReleaseDate = _queueParseReleaseDate(releaseDate) != null;
  final hasGenre = _queueHasMetadataValue(genre);
  final hasTrackNumber = trackNumber != null && trackNumber > 0;
  final hasDiscNumber = discNumber != null && discNumber > 0;
  final hasLabel = _queueHasMetadataValue(label);
  final hasIncorrectIsrc = _queueHasIncorrectIsrcFormat(isrc);
  final isComplete =
      hasArtist &&
      hasAlbumArtist &&
      hasReleaseDate &&
      hasGenre &&
      hasTrackNumber &&
      hasDiscNumber &&
      hasLabel &&
      !hasIncorrectIsrc;

  switch (filterMetadata) {
    case 'complete':
      return isComplete;
    case 'missing-any':
      return !isComplete;
    case 'missing-year':
      return !hasReleaseDate;
    case 'missing-genre':
      return !hasGenre;
    case 'missing-album-artist':
      return !hasAlbumArtist;
    case 'missing-track-number':
      return !hasTrackNumber;
    case 'missing-disc-number':
      return !hasDiscNumber;
    case 'missing-artist':
      return !hasArtist;
    case 'incorrect-isrc-format':
      return hasIncorrectIsrc;
    case 'missing-label':
      return !hasLabel;
    default:
      return true;
  }
}

bool _queueHasIncorrectIsrcFormat(String? isrc) {
  final raw = isrc?.trim() ?? '';
  if (raw.isEmpty) return false;
  final normalized = raw.toUpperCase().replaceAll(RegExp(r'[-\s]'), '');
  return !RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$').hasMatch(normalized);
}

bool _queueUnifiedItemMatchesMetadataFilter(
  UnifiedLibraryItem item,
  String? filterMetadata,
) {
  return _queueMatchesMetadataFilter(
    filterMetadata: filterMetadata,
    artistName: item.artistName,
    albumArtist: item.albumArtist,
    releaseDate: item.releaseDate,
    genre: item.genre,
    trackNumber: item.trackNumber,
    discNumber: item.discNumber,
    isrc: item.isrc,
    label: item.label,
  );
}

int _queueCompareOptionalText(
  String? left,
  String? right, {
  bool descending = false,
}) {
  final normalizedLeft = _queueNormalizedMetadataValue(left);
  final normalizedRight = _queueNormalizedMetadataValue(right);
  final leftEmpty = normalizedLeft.isEmpty;
  final rightEmpty = normalizedRight.isEmpty;

  if (leftEmpty && rightEmpty) {
    return 0;
  }
  if (leftEmpty) {
    return 1;
  }
  if (rightEmpty) {
    return -1;
  }

  final comparison = normalizedLeft.compareTo(normalizedRight);
  return descending ? -comparison : comparison;
}

int _queueCompareOptionalDate(
  DateTime? left,
  DateTime? right, {
  bool descending = false,
}) {
  if (left == null && right == null) {
    return 0;
  }
  if (left == null) {
    return 1;
  }
  if (right == null) {
    return -1;
  }

  final comparison = left.compareTo(right);
  return descending ? -comparison : comparison;
}

DateTime? _queueGroupedAlbumReleaseDate(_GroupedAlbum album) {
  for (final track in album.tracks) {
    final releaseDate = _queueParseReleaseDate(track.releaseDate);
    if (releaseDate != null) {
      return releaseDate;
    }
  }
  return null;
}

DateTime? _queueGroupedLocalAlbumReleaseDate(_GroupedLocalAlbum album) {
  for (final track in album.tracks) {
    final releaseDate = _queueParseReleaseDate(track.releaseDate);
    if (releaseDate != null) {
      return releaseDate;
    }
  }
  return null;
}

String? _queueGroupedAlbumGenre(_GroupedAlbum album) {
  for (final track in album.tracks) {
    if (_queueHasMetadataValue(track.genre)) {
      return track.genre;
    }
  }
  return null;
}

String? _queueGroupedLocalAlbumGenre(_GroupedLocalAlbum album) {
  for (final track in album.tracks) {
    if (_queueHasMetadataValue(track.genre)) {
      return track.genre;
    }
  }
  return null;
}

String? _queueLocalQualityLabel(LocalLibraryItem item) {
  if (item.bitrate != null && item.bitrate! > 0) {
    return '${item.bitrate}kbps';
  }
  if (item.bitDepth == null || item.bitDepth == 0 || item.sampleRate == null) {
    return null;
  }
  return '${item.bitDepth}bit/${(item.sampleRate! / 1000).toStringAsFixed(1)}kHz';
}

bool _queuePassesQualityFilter(String? filterQuality, String? quality) {
  if (filterQuality == null) return true;
  if (quality == null) return filterQuality == 'lossy';
  final normalized = quality.toLowerCase();
  switch (filterQuality) {
    case 'hires':
      return normalized.startsWith('24');
    case 'cd':
      return normalized.startsWith('16');
    case 'lossy':
      return !normalized.startsWith('24') && !normalized.startsWith('16');
    default:
      return true;
  }
}

bool _queuePassesFormatFilter(String? filterFormat, String filePath) {
  if (filterFormat == null) return true;
  return _queueFileExtLower(filePath) == filterFormat;
}

_HistoryStats _buildQueueHistoryStats(
  List<DownloadHistoryItem> items, [
  List<LocalLibraryItem> localItems = const [],
]) {
  final memo = _queueHistoryStatsMemo;
  if (memo != null &&
      identical(memo.historyItems, items) &&
      identical(memo.localItems, localItems)) {
    return memo.stats;
  }

  final albumCounts = <String, int>{};
  final albumMap = <String, List<DownloadHistoryItem>>{};
  for (final item in items) {
    final key = _queueHistoryAlbumKey(
      item.albumName,
      item.albumArtist ?? item.artistName,
    );
    albumCounts[key] = (albumCounts[key] ?? 0) + 1;
    albumMap.putIfAbsent(key, () => []).add(item);
  }

  var singleTracks = 0;
  var albumCount = 0;
  for (final count in albumCounts.values) {
    if (count > 1) {
      albumCount++;
    } else {
      singleTracks += count;
    }
  }

  final groupedAlbums = <_GroupedAlbum>[];
  albumMap.forEach((_, tracks) {
    if (tracks.length <= 1) return;
    tracks.sort((a, b) {
      final aNum = a.trackNumber ?? 999;
      final bNum = b.trackNumber ?? 999;
      return aNum.compareTo(bNum);
    });

    groupedAlbums.add(
      _GroupedAlbum(
        albumName: tracks.first.albumName,
        artistName: tracks.first.albumArtist ?? tracks.first.artistName,
        coverUrl: tracks.first.coverUrl,
        sampleFilePath: tracks.first.filePath,
        tracks: tracks,
        latestDownload: tracks
            .map((t) => t.downloadedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b),
      ),
    );
  });
  groupedAlbums.sort((a, b) => b.latestDownload.compareTo(a.latestDownload));

  final downloadedPathKeys = <String>{};
  for (final item in items) {
    downloadedPathKeys.addAll(buildPathMatchKeys(item.filePath));
  }

  final dedupedLocalItems = localItems
      .where((item) {
        final localPathKeys = buildPathMatchKeys(item.filePath);
        return !localPathKeys.any(downloadedPathKeys.contains);
      })
      .toList(growable: false);

  final localAlbumCounts = <String, int>{};
  final localAlbumMap = <String, List<LocalLibraryItem>>{};
  for (final item in dedupedLocalItems) {
    final key = _queueHistoryAlbumKey(
      item.albumName,
      item.albumArtist ?? item.artistName,
    );
    localAlbumCounts[key] = (localAlbumCounts[key] ?? 0) + 1;
    localAlbumMap.putIfAbsent(key, () => []).add(item);
  }

  var localAlbumCount = 0;
  var localSingleTracks = 0;
  for (final count in localAlbumCounts.values) {
    if (count > 1) {
      localAlbumCount++;
    } else {
      localSingleTracks++;
    }
  }

  final groupedLocalAlbums = <_GroupedLocalAlbum>[];
  localAlbumMap.forEach((_, tracks) {
    if (tracks.length <= 1) return;
    tracks.sort((a, b) {
      final aNum = a.trackNumber ?? 999;
      final bNum = b.trackNumber ?? 999;
      return aNum.compareTo(bNum);
    });

    groupedLocalAlbums.add(
      _GroupedLocalAlbum(
        albumName: tracks.first.albumName,
        artistName: tracks.first.albumArtist ?? tracks.first.artistName,
        coverPath: tracks
            .firstWhere(
              (t) => t.coverPath != null && t.coverPath!.isNotEmpty,
              orElse: () => tracks.first,
            )
            .coverPath,
        tracks: tracks,
        latestScanned: tracks
            .map((t) => t.scannedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b),
      ),
    );
  });
  groupedLocalAlbums.sort((a, b) => b.latestScanned.compareTo(a.latestScanned));

  final stats = _HistoryStats(
    albumCounts: albumCounts,
    localAlbumCounts: localAlbumCounts,
    groupedAlbums: groupedAlbums,
    groupedLocalAlbums: groupedLocalAlbums,
    albumCount: albumCount,
    singleTracks: singleTracks,
    localAlbumCount: localAlbumCount,
    localSingleTracks: localSingleTracks,
  );
  _queueHistoryStatsMemo = _QueueHistoryStatsMemoEntry(
    historyItems: items,
    localItems: localItems,
    stats: stats,
  );
  return stats;
}

List<_GroupedAlbum> _queueFilterGroupedAlbums(
  List<_GroupedAlbum> albums,
  _QueueGroupedAlbumFilterRequest request,
) {
  if (request.filterSource == 'local') return const [];
  if (request.filterSource == null &&
      request.filterQuality == null &&
      request.filterFormat == null &&
      request.filterMetadata == null &&
      request.searchQuery.isEmpty &&
      request.sortMode == 'latest') {
    return albums;
  }

  final result = <_GroupedAlbum>[];
  for (final album in albums) {
    if (request.searchQuery.isNotEmpty &&
        !album.searchKey.contains(request.searchQuery)) {
      continue;
    }

    if (request.filterQuality != null ||
        request.filterFormat != null ||
        request.filterMetadata != null) {
      var hasMatchingTrack = false;
      for (final track in album.tracks) {
        if (!_queuePassesQualityFilter(request.filterQuality, track.quality)) {
          continue;
        }
        if (!_queuePassesFormatFilter(request.filterFormat, track.filePath)) {
          continue;
        }
        if (!_queueMatchesMetadataFilter(
          filterMetadata: request.filterMetadata,
          artistName: track.artistName,
          albumArtist: track.albumArtist,
          releaseDate: track.releaseDate,
          genre: track.genre,
          trackNumber: track.trackNumber,
          discNumber: track.discNumber,
          isrc: track.isrc,
          label: track.label,
        )) {
          continue;
        }
        hasMatchingTrack = true;
        break;
      }
      if (!hasMatchingTrack) continue;
    }

    result.add(album);
  }

  switch (request.sortMode) {
    case 'oldest':
      result.sort((a, b) => a.latestDownload.compareTo(b.latestDownload));
    case 'artist-asc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          a.artistName,
          b.artistName,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'artist-desc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          a.artistName,
          b.artistName,
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'a-z':
      result.sort(
        (a, b) =>
            a.albumName.toLowerCase().compareTo(b.albumName.toLowerCase()),
      );
    case 'z-a':
      result.sort(
        (a, b) =>
            b.albumName.toLowerCase().compareTo(a.albumName.toLowerCase()),
      );
    case 'album-asc':
      result.sort(
        (a, b) => _queueCompareOptionalText(a.albumName, b.albumName),
      );
    case 'album-desc':
      result.sort(
        (a, b) => _queueCompareOptionalText(
          a.albumName,
          b.albumName,
          descending: true,
        ),
      );
    case 'release-oldest':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalDate(
          _queueGroupedAlbumReleaseDate(a),
          _queueGroupedAlbumReleaseDate(b),
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'release-newest':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalDate(
          _queueGroupedAlbumReleaseDate(a),
          _queueGroupedAlbumReleaseDate(b),
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'genre-asc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          _queueGroupedAlbumGenre(a),
          _queueGroupedAlbumGenre(b),
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'genre-desc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          _queueGroupedAlbumGenre(a),
          _queueGroupedAlbumGenre(b),
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    default:
      break;
  }
  return result;
}

List<_GroupedLocalAlbum> _queueFilterGroupedLocalAlbums(
  List<_GroupedLocalAlbum> albums,
  _QueueGroupedAlbumFilterRequest request,
) {
  if (request.filterSource == 'downloaded') return const [];
  if (request.filterSource == null &&
      request.filterQuality == null &&
      request.filterFormat == null &&
      request.filterMetadata == null &&
      request.searchQuery.isEmpty &&
      request.sortMode == 'latest') {
    return albums;
  }

  final result = <_GroupedLocalAlbum>[];
  for (final album in albums) {
    if (request.searchQuery.isNotEmpty &&
        !album.searchKey.contains(request.searchQuery)) {
      continue;
    }

    if (request.filterQuality != null ||
        request.filterFormat != null ||
        request.filterMetadata != null) {
      var hasMatchingTrack = false;
      for (final track in album.tracks) {
        if (!_queuePassesQualityFilter(
          request.filterQuality,
          _queueLocalQualityLabel(track),
        )) {
          continue;
        }
        if (!_queuePassesFormatFilter(request.filterFormat, track.filePath)) {
          continue;
        }
        if (!_queueMatchesMetadataFilter(
          filterMetadata: request.filterMetadata,
          artistName: track.artistName,
          albumArtist: track.albumArtist,
          releaseDate: track.releaseDate,
          genre: track.genre,
          trackNumber: track.trackNumber,
          discNumber: track.discNumber,
          isrc: track.isrc,
          label: track.label,
        )) {
          continue;
        }
        hasMatchingTrack = true;
        break;
      }
      if (!hasMatchingTrack) continue;
    }

    result.add(album);
  }

  switch (request.sortMode) {
    case 'oldest':
      result.sort((a, b) => a.latestScanned.compareTo(b.latestScanned));
    case 'artist-asc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          a.artistName,
          b.artistName,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'artist-desc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          a.artistName,
          b.artistName,
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'a-z':
      result.sort(
        (a, b) =>
            a.albumName.toLowerCase().compareTo(b.albumName.toLowerCase()),
      );
    case 'z-a':
      result.sort(
        (a, b) =>
            b.albumName.toLowerCase().compareTo(a.albumName.toLowerCase()),
      );
    case 'album-asc':
      result.sort(
        (a, b) => _queueCompareOptionalText(a.albumName, b.albumName),
      );
    case 'album-desc':
      result.sort(
        (a, b) => _queueCompareOptionalText(
          a.albumName,
          b.albumName,
          descending: true,
        ),
      );
    case 'release-oldest':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalDate(
          _queueGroupedLocalAlbumReleaseDate(a),
          _queueGroupedLocalAlbumReleaseDate(b),
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'release-newest':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalDate(
          _queueGroupedLocalAlbumReleaseDate(a),
          _queueGroupedLocalAlbumReleaseDate(b),
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'genre-asc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          _queueGroupedLocalAlbumGenre(a),
          _queueGroupedLocalAlbumGenre(b),
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    case 'genre-desc':
      result.sort((a, b) {
        final comparison = _queueCompareOptionalText(
          _queueGroupedLocalAlbumGenre(a),
          _queueGroupedLocalAlbumGenre(b),
          descending: true,
        );
        if (comparison != 0) {
          return comparison;
        }
        return _queueCompareOptionalText(a.albumName, b.albumName);
      });
    default:
      break;
  }
  return result;
}

final _queueHistoryStatsProvider = Provider<_HistoryStats>((ref) {
  final historyItems = ref.watch(
    downloadHistoryProvider.select((s) => s.items),
  );
  final localLibraryEnabled = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  final localItems = localLibraryEnabled
      ? ref.watch(localLibraryProvider.select((s) => s.items))
      : const <LocalLibraryItem>[];
  return _buildQueueHistoryStats(historyItems, localItems);
});

final _queueFilteredAlbumsProvider =
    Provider.family<
      ({List<_GroupedAlbum> albums, List<_GroupedLocalAlbum> localAlbums}),
      _QueueGroupedAlbumFilterRequest
    >((ref, request) {
      final historyStats = ref.watch(_queueHistoryStatsProvider);
      return (
        albums: _queueFilterGroupedAlbums(historyStats.groupedAlbums, request),
        localAlbums: _queueFilterGroupedLocalAlbums(
          historyStats.groupedLocalAlbums,
          request,
        ),
      );
    });

Map<String, List<String>> _filterHistoryInIsolate(Map<String, Object> payload) {
  final entries = (payload['entries'] as List).cast<List<Object?>>();
  final albumCounts = Map<String, int>.from(payload['albumCounts'] as Map);
  final query = (payload['query'] as String?) ?? '';
  final hasQuery = query.isNotEmpty;

  final allIds = <String>[];
  final albumIds = <String>[];
  final singleIds = <String>[];

  for (final entry in entries) {
    final id = entry[0] as String;
    final albumKey = entry[1] as String;
    if (hasQuery) {
      final searchKey = entry[2] as String;
      if (!searchKey.contains(query)) {
        continue;
      }
    }

    allIds.add(id);
    final count = albumCounts[albumKey] ?? 0;
    if (count > 1) {
      albumIds.add(id);
    } else if (count == 1) {
      singleIds.add(id);
    }
  }

  return {'all': allIds, 'albums': albumIds, 'singles': singleIds};
}
