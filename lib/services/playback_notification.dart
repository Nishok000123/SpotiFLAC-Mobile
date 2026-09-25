import 'package:audio_service/audio_service.dart';

/// Presentation only; every transport action still uses the audio handler.
class PlaybackNotification {
  static const favoriteAction = 'spotiflac.favorite';
  static const outputAction = 'spotiflac.audioOutput';

  final bool mornye;
  final String? mediaId;
  final String? source;
  final bool loved;
  final String favoriteLabel;
  final String outputLabel;

  const PlaybackNotification({
    this.mornye = false,
    this.mediaId,
    this.source,
    this.loved = false,
    this.favoriteLabel = 'Favorite',
    this.outputLabel = 'Audio Output',
  });

  List<MediaControl> controls({
    required bool playing,
    required MediaItem? item,
  }) {
    if (!mornye) {
      return [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ];
    }
    final current = item?.id == mediaId && item?.extras?['source'] == source;
    return [
      MediaControl.custom(
        name: favoriteAction,
        androidIcon: current && loved
            ? 'drawable/ic_notification_star_filled'
            : 'drawable/ic_notification_star',
        label: favoriteLabel,
      ),
      MediaControl.skipToPrevious.copyWith(
        androidIcon: 'drawable/ic_widget_previous',
      ),
      (playing ? MediaControl.pause : MediaControl.play).copyWith(
        androidIcon: playing
            ? 'drawable/ic_widget_pause'
            : 'drawable/ic_widget_play',
      ),
      MediaControl.skipToNext.copyWith(androidIcon: 'drawable/ic_widget_next'),
      MediaControl.custom(
        name: outputAction,
        androidIcon: 'drawable/ic_notification_airplay',
        label: outputLabel,
        extras: const {
          'spotiflac.activity': 'com.zarz.spotiflac.AudioOutputActivity',
        },
      ),
    ];
  }
}
