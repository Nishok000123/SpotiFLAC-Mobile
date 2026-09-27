import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

PlayableMedia track(
  String id, {
  String artist = 'Artist',
  String? genre,
  String? source,
}) => PlayableMedia(
  id: id,
  source: source ?? '/$id.flac',
  title: id,
  artist: artist,
  genre: genre,
);

void main() {
  test('Autoplay prefers related unplayed Library tracks and deduplicates', () {
    final seed = track('seed', genre: 'Rock');
    final related = track('related', genre: 'Rock');
    final recent = track('recent', genre: 'Rock');
    final selected = selectAutoplayTracks(
      seed: seed,
      candidates: [
        seed,
        related,
        related,
        recent,
        track('unrelated', artist: 'Other'),
        track('queued'),
        track('dismissed'),
        track('remote', source: 'https://example.com/audio.flac'),
        track('related', source: '/copy.flac', genre: 'Rock'),
      ],
      upcoming: [track('queued')],
      recent: [recent],
      dismissedSources: {'/dismissed.flac'},
      random: Random(1),
    );
    expect(selected.map((item) => item.id), ['related', 'unrelated', 'recent']);
  });

  test('a small Library never recommends the current song to itself', () {
    final seed = track('only');
    expect(
      selectAutoplayTracks(
        seed: seed,
        candidates: [seed],
        upcoming: [],
        recent: [seed],
        dismissedSources: {},
        random: Random(1),
      ),
      isEmpty,
    );
  });

  test('Autoplay preference and recommendation provenance survive restore', () {
    expect(AppSettings.fromJson({}).autoplay, isFalse);
    final settings = const AppSettings().copyWith(autoplay: true);
    expect(AppSettings.fromJson(settings.toJson()).autoplay, isTrue);
    final media = PlayableMedia.fromJson({
      ...track('one', genre: 'Rock').toJson(),
      'autoplay': true,
    })!;
    final restored = PlayableMedia.fromJson(media.toJson())!;
    expect(restored.autoplay, isTrue);
    expect(restored.genre, 'Rock');
    expect(restored.toMediaItem().extras?['autoplay'], isTrue);
  });
}
