import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/utils/synced_lyrics_scroll.dart';

/// A playback-driven countdown, rather than a repeating loading animation.
class LyricGapIndicator extends ConsumerWidget {
  const LyricGapIndicator({
    super.key,
    required this.start,
    required this.end,
    required this.color,
    this.position,
  });

  final Duration start;
  final Duration end;
  final Color color;
  final Duration? position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = syncedLyricSegmentProgress(
      position: position ?? ref.watch(playbackPositionProvider),
      start: start,
      end: end,
    );
    final animate =
        ref.watch(playbackPlayingProvider) &&
        !ref.watch(playbackLoadingProvider) &&
        !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: context.l10n.nowPlayingInstrumental,
      value: '${(progress * 100).round()}%',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < 3; index++) ...[
            if (index > 0) const SizedBox(width: 8),
            AnimatedContainer(
              key: ValueKey('lyric-gap-dot-$index'),
              duration: animate
                  ? const Duration(milliseconds: 120)
                  : Duration.zero,
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(
                  color.withValues(alpha: 0.25),
                  color,
                  (progress * 3 - index).clamp(0.0, 1.0),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
