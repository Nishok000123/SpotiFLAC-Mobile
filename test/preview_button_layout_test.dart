import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/widgets/preview_button.dart';

void main() {
  const track = Track(
    id: 'track-1',
    name: 'Track',
    artistName: 'Artist',
    albumName: 'Album',
    previewUrl: 'https://example.com/preview.mp3',
    duration: 180,
  );

  Future<void> pumpButton(WidgetTester tester, {MediaItem? currentItem}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWith(
            (ref) => Stream.value(currentItem),
          ),
          playbackPlayingProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: PreviewButton(track: track)),
        ),
      ),
    );
    await tester.pump();
  }

  void expectCenteredHitbox(WidgetTester tester, IconData iconData) {
    final button = find.byType(IconButton);
    final icon = find.byIcon(iconData);
    final hitbox = tester.getRect(button);

    expect(hitbox.width, greaterThanOrEqualTo(48));
    expect(hitbox.height, greaterThanOrEqualTo(48));
    expect(tester.getCenter(icon), hitbox.center);
  }

  testWidgets('preview icon is centered inside its 48dp hitbox', (
    tester,
  ) async {
    await pumpButton(tester);
    expectCenteredHitbox(tester, Icons.play_circle_outline_rounded);
  });

  testWidgets('current-track play icon uses the same centered hitbox', (
    tester,
  ) async {
    await pumpButton(
      tester,
      currentItem: const MediaItem(
        id: 'track-1',
        title: 'Track',
        artist: 'Artist',
      ),
    );
    expectCenteredHitbox(tester, Icons.play_circle_fill_rounded);
  });
}
