import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/int_utils.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

/// Shared preparation before either queue chooses folders, filenames or tags.
Future<Track> enrichIncompleteDownloadTrack(
  Track track,
  String providerId,
  String providerTrackId, {
  Future<Map<String, dynamic>> Function(String, String, String)? loadMetadata,
}) async {
  if (normalizeOptionalString(track.isrc) != null &&
      (track.trackNumber ?? 0) > 0 &&
      (track.totalTracks ?? 0) > 0 &&
      normalizeOptionalString(track.composer) != null) {
    return track;
  }
  try {
    final response = await (loadMetadata ?? PlatformBridge.getProviderMetadata)(
      providerId,
      'track',
      providerTrackId,
    ).timeout(const Duration(seconds: 8));
    final data = response['track'];
    if (data is! Map<String, dynamic>) return track;
    String? text(String key) => normalizeOptionalString(data[key]?.toString());
    final durationMs = readPositiveInt(data['duration_ms']);
    return track.copyWith(
      id: text('spotify_id') ?? track.id,
      name: text('name') ?? track.name,
      artistName: text('artists') ?? track.artistName,
      albumName: text('album_name') ?? track.albumName,
      albumArtist: text('album_artist') ?? track.albumArtist,
      artistId: text('artist_id') ?? text('artistId') ?? track.artistId,
      albumId: text('album_id') ?? track.albumId,
      coverUrl: text('images') ?? track.coverUrl,
      duration: durationMs == null ? track.duration : durationMs ~/ 1000,
      isrc: text('isrc') ?? track.isrc,
      trackNumber: readPositiveInt(data['track_number']) ?? track.trackNumber,
      discNumber: readPositiveInt(data['disc_number']) ?? track.discNumber,
      totalDiscs: readPositiveInt(data['total_discs']) ?? track.totalDiscs,
      releaseDate: text('release_date') ?? track.releaseDate,
      albumType: text('album_type') ?? track.albumType,
      totalTracks: readPositiveInt(data['total_tracks']) ?? track.totalTracks,
      composer: text('composer') ?? track.composer,
      genre: text('genre') ?? track.genre,
      label: text('label') ?? track.label,
      copyright: text('copyright') ?? track.copyright,
      comment: text('comment') ?? track.comment,
      explicit: parseExplicitFlag(data['explicit']) ?? track.explicit,
      upc: text('upc') ?? text('barcode') ?? track.upc,
    );
  } catch (error) {
    AppLogger('DownloadMetadata').w('Track enrichment failed: $error');
    return track;
  }
}
