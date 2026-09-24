import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/theme/cover_palette.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_context_menu.dart';

/// Navigation for the title/artist, separate from playback and file actions.
class MornyePlayerNavigationMenu extends StatelessWidget {
  const MornyePlayerNavigationMenu({super.key, required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context) {
    final theme = MornyeTheme.build(Brightness.dark);
    final art = mediaItem.artUri;
    final source = art?.scheme == 'file' ? art!.toFilePath() : art?.toString();
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(primary: Colors.grey),
      ),
      child: CoverPaletteBuilder(
        imageSource: source,
        builder: (context, _) {
          final dominant = HSLColor.fromColor(
            source == null
                ? Colors.grey
                : CoverPalette.sourceColor(source, Brightness.dark) ??
                      Colors.grey,
          );
          final surface = dominant
              .withSaturation(dominant.saturation.clamp(0.0, 0.28))
              .withLightness(0.28)
              .toColor();
          return Theme(
            data: theme.copyWith(
              colorScheme: theme.colorScheme.copyWith(
                surfaceContainerHigh: surface,
              ),
            ),
            child: MornyeContextMenu(
              inheritSurface: true,
              dense: true,
              groups: [
                [
                  if ((mediaItem.artist ?? '').trim().isNotEmpty)
                    MornyeMenuAction(
                      icon: CupertinoIcons.mic,
                      label: context.l10n.mornyeGoToArtist,
                      subtitle: mediaItem.artist,
                      onPressed: () => Navigator.of(context).pop('artist'),
                    ),
                  if ((mediaItem.album ?? '').trim().isNotEmpty)
                    MornyeMenuAction(
                      icon: CupertinoIcons.square_stack,
                      label: context.l10n.homeGoToAlbum,
                      subtitle: mediaItem.album,
                      onPressed: () => Navigator.of(context).pop('album'),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A floating menu that inherits the player's dark appearance.
class MornyePlayerActionsSheet extends ConsumerWidget {
  const MornyePlayerActionsSheet({
    super.key,
    required this.mediaItem,
    this.sleepTimerSubtitle,
  });

  final MediaItem mediaItem;
  final String? sleepTimerSubtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerCollectionTrackProvider(mediaItem)).value;
    final loved = ref.watch(
      libraryCollectionsProvider.select(
        (state) => track != null && state.isLoved(track),
      ),
    );
    return MornyeContextMenu(
      dense: true,
      quickActions: [
        _action(
          context,
          'favorite',
          loved ? context.l10n.mornyeFavorited : context.l10n.mornyeFavorite,
          CupertinoIcons.star_fill,
          selected: loved,
        ),
        _action(
          context,
          'share',
          context.l10n.trackMetadataShare,
          CupertinoIcons.share_solid,
        ),
      ],
      groups: [
        [
          _action(
            context,
            'playlist',
            context.l10n.collectionAddToPlaylist,
            CupertinoIcons.text_badge_plus,
          ),
        ],
        [
          if ((mediaItem.album ?? '').trim().isNotEmpty)
            _action(
              context,
              'album',
              context.l10n.homeGoToAlbum,
              CupertinoIcons.square_stack,
              subtitle: mediaItem.album,
            ),
          if ((mediaItem.artist ?? '').trim().isNotEmpty)
            _action(
              context,
              'artist',
              context.l10n.mornyeGoToArtist,
              CupertinoIcons.mic,
              subtitle: mediaItem.artist,
            ),
          _action(
            context,
            'details',
            context.l10n.nowPlayingDetails,
            CupertinoIcons.info,
          ),
        ],
        [
          _action(
            context,
            'sleepTimer',
            context.l10n.nowPlayingSleepTimer,
            CupertinoIcons.moon_zzz,
            subtitle: sleepTimerSubtitle,
          ),
          _action(
            context,
            'external',
            context.l10n.nowPlayingOpenInExternalPlayer,
            CupertinoIcons.arrow_up_right_square,
          ),
        ],
      ],
    );
  }

  MornyeMenuAction _action(
    BuildContext context,
    String value,
    String label,
    IconData icon, {
    String? subtitle,
    bool selected = false,
  }) => MornyeMenuAction(
    icon: icon,
    label: label,
    subtitle: subtitle,
    selected: selected,
    onPressed: () => Navigator.of(context).pop(value),
  );
}
