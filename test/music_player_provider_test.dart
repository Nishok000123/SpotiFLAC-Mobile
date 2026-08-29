import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';

void main() {
  test('Library playback state follows only the current media item', () async {
    final container = ProviderContainer(
      overrides: [
        currentMediaItemProvider.overrideWith(
          (ref) =>
              Stream.value(const MediaItem(id: 'track-1', title: 'Track 1')),
        ),
        playbackPlayingProvider.overrideWith((ref) => true),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    final currentMediaSubscription = container.listen(
      currentMediaItemProvider,
      (_, _) {},
    );
    addTearDown(currentMediaSubscription.close);

    await container.read(currentMediaItemProvider.future);

    expect(container.read(mediaItemPlaybackUiProvider('track-1')), (
      isCurrent: true,
      isPlaying: true,
      isLoading: false,
    ));
    expect(container.read(mediaItemPlaybackUiProvider('track-2')), (
      isCurrent: false,
      isPlaying: false,
      isLoading: false,
    ));
  });
}
