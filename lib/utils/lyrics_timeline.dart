import 'package:spotiflac_android/utils/lyrics_parser.dart';

/// Inserts empty, bounded rows for instrumental countdowns in the player.
/// Unmarked gaps in plain LRC cannot be distinguished from held vocals: only
/// use explicit empty timestamps or known line/word ends, never an estimate.
List<LyricLine> lyricsTimelineWithGaps(List<LyricLine> lines) {
  const minimumGap = Duration(seconds: 3);
  final timeline = <LyricLine>[];
  Duration? gapStart;
  Duration? latestVocalEnd;

  for (final line in lines) {
    if (line.text.trim().isEmpty) {
      gapStart ??= line.time;
      continue;
    }

    var start = timeline.isEmpty ? Duration.zero : gapStart;
    // A second vocal line may overlap a previous, longer one.
    if (start != null && latestVocalEnd != null && start < latestVocalEnd) {
      start = latestVocalEnd;
    }
    if (start != null && line.time - start >= minimumGap) {
      timeline.add(LyricLine(time: start, end: line.time, text: ''));
    }
    timeline.add(line);

    final lastWord = line.words.lastOrNull;
    var end = line.end;
    if (lastWord != null) {
      if (lastWord.end != null && (end == null || lastWord.end! > end)) {
        end = lastWord.end;
      }
      if (end != null && end < lastWord.time) end = null;
    }
    if (end != null && end < line.time) end = null;
    gapStart = end;
    if (end != null && (latestVocalEnd == null || end > latestVocalEnd)) {
      latestVocalEnd = end;
    }
  }
  // No following vocal means no countdown: trailing blank timestamps are
  // intentionally omitted, and credits stay after the last sung line.
  return List.unmodifiable(timeline);
}
