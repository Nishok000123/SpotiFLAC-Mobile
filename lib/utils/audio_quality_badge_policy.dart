const highQualityBadgeBitrateThresholdKbps = 900;

/// Preserves the highlighted color used by legacy 24-bit Library badges while
/// also supporting newer labels that display a measured bitrate instead.
bool shouldHighlightAudioQualityBadge(String quality) {
  final normalized = quality.trim().toLowerCase();
  if (RegExp(r'\b24(?:\s*[- ]?\s*bit|/)').hasMatch(normalized)) {
    return true;
  }

  final kbpsMatch = RegExp(
    r'\b(\d+(?:\.\d+)?)\s*k(?:bps)?\b',
  ).firstMatch(normalized);
  final kbps = double.tryParse(kbpsMatch?.group(1) ?? '');
  if (kbps != null) {
    return kbps > highQualityBadgeBitrateThresholdKbps;
  }

  final mbpsMatch = RegExp(
    r'\b(\d+(?:\.\d+)?)\s*mbps\b',
  ).firstMatch(normalized);
  final mbps = double.tryParse(mbpsMatch?.group(1) ?? '');
  return mbps != null && mbps * 1000 > highQualityBadgeBitrateThresholdKbps;
}
