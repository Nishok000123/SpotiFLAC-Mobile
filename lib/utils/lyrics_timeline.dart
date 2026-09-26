import 'package:spotiflac_android/utils/lyrics_parser.dart';

/// Keep overlapping vocal parts lit until their explicit end. Untimed lines
/// retain the normal single-line behavior instead of guessing a vocal length.
Set<int> activeLyricIndices(
  List<LyricLine> lines,
  Duration position,
  int currentIndex,
) {
  final active = <int>{};
  for (var i = 0; i <= currentIndex; i++) {
    final line = lines[i];
    final timedVoice =
        (i < currentIndex || line.voice != null || line.isBackground) &&
        line.text.isNotEmpty &&
        line.end != null;
    // Known ends also apply to the most recently started singer, so a short
    // reply does not stay lit over a longer lead vocal.
    if (timedVoice ? line.end! > position : i == currentIndex) active.add(i);
  }
  return active;
}

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
