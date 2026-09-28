import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/download_track_metadata.dart';

void main() {
  const original = Track(
    id: 'example:track',
    source: 'example',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 8,
    trackNumber: 0,
    albumId: 'album',
    previewUrl: 'https://example.test/preview',
    audioQuality: 'LOSSLESS',
    audioModes: 'STEREO',
  );

  test(
    'both download paths receive full credits, numbering and cover before naming',
    () async {
      final enriched = await enrichIncompleteDownloadTrack(
        original,
        'example',
        'track',
        loadMetadata: (provider, type, id) async {
          expect([provider, type, id], ['example', 'track', 'track']);
          return {
            'track': {
              'album_artist': 'Album Artist',
              'album_name': 'Resolved Album',
              'track_number': 3,
              'total_tracks': 12,
              'disc_number': 2,
              'total_discs': 2,
              'composer': 'Composer',
              'isrc': 'USAAA2400001',
              'duration_ms': 8000,
              'images': 'https://example.test/cover',
              'explicit': true,
              'upc': '123456789012',
            },
          };
        },
      );
      expect(enriched.toJson(), {
        ...original.toJson(),
        'albumArtist': 'Album Artist',
        'albumName': 'Resolved Album',
        'trackNumber': 3,
        'totalTracks': 12,
        'discNumber': 2,
        'totalDiscs': 2,
        'composer': 'Composer',
        'isrc': 'USAAA2400001',
        'coverUrl': 'https://example.test/cover',
        'explicit': true,
        'upc': '123456789012',
      });
    },
  );

  test('empty optional fields do not erase existing metadata', () async {
    final enriched = await enrichIncompleteDownloadTrack(
      original,
      'example',
      'track',
      loadMetadata: (_, _, _) async => {
        'track': {
          'name': '',
          'album_name': null,
          'duration_ms': 0,
          'disc_number': -1,
        },
      },
    );
    expect(enriched.toJson(), original.toJson());
  });

  test(
    'complete tracks avoid an extra lookup and failed lookups keep source metadata',
    () async {
      var calls = 0;
      Future<Map<String, dynamic>> load(
        String provider,
        String type,
        String id,
      ) async {
        calls++;
        throw StateError('provider unavailable');
      }

      final complete = original.copyWith(
        isrc: 'USAAA2400001',
        trackNumber: 1,
        totalTracks: 12,
        composer: 'Composer',
      );
      expect(
        await enrichIncompleteDownloadTrack(
          complete,
          'example',
          'track',
          loadMetadata: load,
        ),
        same(complete),
      );
      expect(calls, 0);
      expect(
        await enrichIncompleteDownloadTrack(
          original,
          'example',
          'track',
          loadMetadata: load,
        ),
        same(original),
      );
      expect(calls, 1);
    },
  );
}
