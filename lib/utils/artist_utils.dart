final RegExp _artistNameSplitPattern = RegExp(
  r'\s*(?:,|;|&|\bx\b)\s*|\s+\b(?:feat(?:uring)?|ft|with)\.?(?=\s|$)\s*',
  caseSensitive: false,
);

const artistTagModeJoined = 'joined';
const artistTagModeSplitVorbis = 'split_vorbis';

List<String> splitArtistNames(String rawArtists) {
  final raw = rawArtists.trim();
  if (raw.isEmpty) return const [];

  return raw
      .split(_artistNameSplitPattern)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String primaryArtistName(String artists, {String? albumArtist}) {
  final preferred = albumArtist?.trim() ?? '';
  final normalizedPreferred = preferred.toLowerCase();
  final useAlbumArtist =
      preferred.isNotEmpty &&
      normalizedPreferred != 'various artists' &&
      normalizedPreferred != 'various' &&
      normalizedPreferred != 'va';
  final source = useAlbumArtist ? preferred : artists.trim();
  final split = splitArtistNames(source);
  if (split.isNotEmpty) return split.first;

  final fallback = splitArtistNames(artists);
  return fallback.isNotEmpty ? fallback.first : artists.trim();
}

bool shouldSplitVorbisArtistTags(String mode) {
  return mode == artistTagModeSplitVorbis;
}

List<String> splitArtistTagValues(String rawArtists) {
  final seen = <String>{};
  final values = <String>[];
  for (final part in splitArtistNames(rawArtists)) {
    final key = part.toLowerCase();
    if (seen.add(key)) {
      values.add(part);
    }
  }

  if (values.isNotEmpty) {
    return values;
  }

  final trimmed = rawArtists.trim();
  return trimmed.isEmpty ? const [] : <String>[trimmed];
}
