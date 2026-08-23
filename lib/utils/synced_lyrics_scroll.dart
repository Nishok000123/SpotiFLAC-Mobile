import 'dart:math' as math;

/// Symmetric list padding that lets the first and last lyric lines reach the
/// vertical center instead of getting pinned to a viewport edge.
double syncedLyricsCenterPadding({
  required double viewportDimension,
  required double estimatedLineExtent,
  double minimumPadding = 24,
}) {
  return math.max(
    minimumPadding,
    (viewportDimension - estimatedLineExtent) / 2,
  );
}

/// Estimated scroll offset when symmetric center padding is applied.
double syncedLyricsEstimatedOffset({
  required int index,
  required double estimatedLineExtent,
}) {
  if (index <= 0) return 0;
  return index * estimatedLineExtent;
}

/// Advances to the final lyric line whose timestamp is already due.
int syncedLyricsDueLineIndex({
  required List<Duration> lineStarts,
  required int currentIndex,
  required Duration position,
}) {
  if (lineStarts.isEmpty) return -1;
  var dueIndex = currentIndex;
  if (dueIndex < -1) dueIndex = -1;
  if (dueIndex >= lineStarts.length) dueIndex = lineStarts.length - 1;
  while (dueIndex + 1 < lineStarts.length &&
      lineStarts[dueIndex + 1] <= position) {
    dueIndex++;
  }
  return dueIndex;
}

/// Extrapolates the latest player position for the lyrics animation only.
///
/// The global playback state intentionally updates at a lower frequency to
/// avoid rebuilding unrelated UI on every frame. The active lyric line uses
/// this value to animate between those updates.
Duration interpolatedSyncedLyricsPosition({
  required Duration anchorPosition,
  required Duration elapsedSinceAnchor,
  required bool isPlaying,
}) {
  if (!isPlaying || elapsedSinceAnchor.isNegative) return anchorPosition;
  return anchorPosition + elapsedSinceAnchor;
}

/// Keeps small timing corrections from making the lyric highlight jump while
/// still applying a seek or another large position change immediately.
Duration reconcileSyncedLyricsPosition({
  required Duration predictedPosition,
  required Duration reportedPosition,
  Duration seekThreshold = const Duration(milliseconds: 750),
}) {
  final drift = (reportedPosition - predictedPosition).abs();
  if (drift >= seekThreshold) return reportedPosition;

  const correctionFraction = 0.25;
  final correction =
      ((reportedPosition - predictedPosition).inMicroseconds *
              correctionFraction)
          .round();
  return predictedPosition + Duration(microseconds: correction);
}

/// Continuous progress for one timed TTML or enhanced LRC segment.
double syncedLyricSegmentProgress({
  required Duration position,
  required Duration start,
  required Duration end,
}) {
  if (position <= start) return 0;
  if (position >= end || end <= start) return 1;
  return (position - start).inMicroseconds / (end - start).inMicroseconds;
}

/// Horizontal leading edge for a highlight that fills left to right.
double syncedLyricsLeftToRightBoundary({
  required double left,
  required double right,
  required double progress,
}) {
  final value = progress.clamp(0.0, 1.0);
  return left + ((right - left) * value);
}
