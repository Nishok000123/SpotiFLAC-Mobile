import 'dart:convert';

import 'package:xml/xml.dart';

class LyricWord {
  final Duration time;
  final Duration? end;
  final String text;

  const LyricWord({required this.time, this.end, required this.text});
}

class LyricLine {
  final Duration time;
  final Duration? end;
  final String text;
  final List<LyricWord> words;
  final String? romanization;
  final List<LyricWord> romanizationWords;
  final String? translation;

  const LyricLine({
    required this.time,
    this.end,
    required this.text,
    this.words = const [],
    this.romanization,
    this.romanizationWords = const [],
    this.translation,
  });

  bool get hasWordTiming => words.isNotEmpty;
}

class ParsedLyrics {
  final bool synced;
  final bool wordSynced;
  final List<LyricLine> lines;
  final String plainText;
  final String? writers;
  final String? provider;

  const ParsedLyrics({
    required this.synced,
    required this.wordSynced,
    required this.lines,
    required this.plainText,
    this.writers,
    this.provider,
  });

  bool get isEmpty => lines.isEmpty && plainText.trim().isEmpty;

  static const ParsedLyrics empty = ParsedLyrics(
    synced: false,
    wordSynced: false,
    lines: [],
    plainText: '',
  );
}

class LyricsParser {
  LyricsParser._();

  // [mm:ss.xx] or [mm:ss.xxx] or [mm:ss]
  static final RegExp _lineTimeTag = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );

  // <mm:ss.xx> inline word timestamp (enhanced LRC).
  static final RegExp _wordTimeTag = RegExp(
    r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>',
  );

  // ID tags such as [ti:..], [ar:..], [offset:..].
  static final RegExp _idTag = RegExp(
    r'^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$',
    caseSensitive: false,
  );
  static final RegExp _supplementTag = RegExp(
    r'^\[x-(romaji-words|romaji|translation):(\d+):([^\]]*)\]$',
    caseSensitive: false,
  );

  static ParsedLyrics parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return ParsedLyrics.empty;

    if (_looksLikeTtml(text)) {
      final ttml = _parseTtml(text);
      if (ttml != null && ttml.lines.isNotEmpty) {
        return _withCredits(text, ttml);
      }
    }

    return _withCredits(text, _parseLrcOrPlain(text));
  }

  static ParsedLyrics _withCredits(String raw, ParsedLyrics lyrics) {
    String? tag(String name) => RegExp(
      '^\\[$name:([^\\]\\r\\n]*)\\]\\s*\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw)?.group(1)?.trim();
    var writers = tag('au');
    var provider = tag('x-provider');
    final credit = tag('by') ?? '';
    provider ??= RegExp(r'\bvia\s+([^\(]+)', caseSensitive: false)
        .firstMatch(credit)
        ?.group(1)
        ?.trim()
        .replaceFirst(RegExp(r'\s+API$', caseSensitive: false), '');
    provider ??= RegExp(
      r'\(source:\s*([^\)]+)\)',
      caseSensitive: false,
    ).firstMatch(credit)?.group(1)?.trim();
    provider = provider?.replaceFirst(
      RegExp(r'^extension:', caseSensitive: false),
      '',
    );
    if (_looksLikeTtml(raw)) {
      try {
        final doc = XmlDocument.parse(raw);
        final names = doc.descendants
            .whereType<XmlElement>()
            .where((node) => node.name.local == 'songwriter')
            .map((node) => node.innerText.trim())
            .where((name) => name.isNotEmpty)
            .toSet();
        if (names.isNotEmpty) writers = names.join(', ');
      } on XmlParserException {
        // Malformed optional credits must not prevent lyric playback.
      }
    }
    var lines = lyrics.lines;
    if (lines.isNotEmpty) {
      final trailer = RegExp(
        r'^Written\s+by\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(lines.last.text.trim());
      if (trailer != null) {
        writers ??= trailer.group(1)?.trim();
        lines = lines.sublist(0, lines.length - 1);
      }
    }
    return ParsedLyrics(
      synced: lyrics.synced,
      wordSynced: lyrics.wordSynced,
      lines: lines,
      plainText: identical(lines, lyrics.lines)
          ? lyrics.plainText
          : lines.map((line) => line.text).join('\n'),
      writers: writers?.isNotEmpty == true ? writers : null,
      provider: provider?.isNotEmpty == true ? provider : null,
    );
  }

  static bool _looksLikeTtml(String text) {
    final head = text.trimLeft();
    return head.startsWith('<?xml') ||
        head.startsWith('<tt') ||
        head.contains('<tt ') ||
        head.contains('http://www.w3.org/ns/ttml');
  }

  static Duration? _toDuration(String? min, String? sec, String? frac) {
    if (min == null || sec == null) return null;
    final m = int.tryParse(min) ?? 0;
    final s = int.tryParse(sec) ?? 0;
    var ms = 0;
    if (frac != null && frac.isNotEmpty) {
      // Normalize to milliseconds regardless of 2 or 3 digit fractions.
      final padded = frac.padRight(3, '0').substring(0, 3);
      ms = int.tryParse(padded) ?? 0;
    }
    return Duration(minutes: m, seconds: s, milliseconds: ms);
  }

  static ParsedLyrics _parseLrcOrPlain(String text) {
    final rawLines = text.split(RegExp(r'\r\n|\r|\n'));
    final parsed = <LyricLine>[];
    final plainBuffer = <String>[];
    final romanization = <int, String>{};
    final romanizationWords = <int, List<LyricWord>>{};
    final translation = <int, String>{};
    var sawTimestamp = false;
    var sawWordTiming = false;
    var offsetMs = 0;

    for (final rawLine in rawLines) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;

      final supplement = _supplementTag.firstMatch(line.trim());
      if (supplement != null) {
        final time = int.tryParse(supplement.group(2)!);
        try {
          final value = utf8.decode(base64.decode(supplement.group(3)!)).trim();
          if (time != null && value.isNotEmpty) {
            final kind = supplement.group(1)!.toLowerCase();
            if (kind == 'romaji-words') {
              final words = _parseRomanizationWords(value);
              if (words.isNotEmpty) {
                romanizationWords.putIfAbsent(time, () => words);
              }
            } else {
              final target = kind == 'romaji' ? romanization : translation;
              target.putIfAbsent(time, () => value);
            }
          }
        } on FormatException {
          // Optional corrupt metadata must not hide the original lyrics.
        }
        continue;
      }

      // Capture [offset:] for timing correction, drop other ID tags.
      final idMatch = _idTag.firstMatch(line.trim());
      if (idMatch != null) {
        final key = idMatch.group(1)!.toLowerCase();
        if (key == 'offset') {
          final value = line
              .substring(line.indexOf(':') + 1)
              .replaceAll(']', '')
              .trim();
          offsetMs = int.tryParse(value) ?? 0;
        }
        continue;
      }

      final timeMatches = _lineTimeTag.allMatches(line).toList();
      if (timeMatches.isEmpty) {
        // No timestamp: treat as plain text line.
        plainBuffer.add(line.trim());
        continue;
      }

      sawTimestamp = true;

      // Strip leading line timestamps to obtain the lyric content.
      final lastTag = timeMatches.last;
      final content = line.substring(lastTag.end).trim();

      // Enhanced LRC word timestamps inside the content.
      final words = _parseWords(content);
      if (words.isNotEmpty) sawWordTiming = true;
      final cleanContent = content.replaceAll(_wordTimeTag, '').trim();
      plainBuffer.add(cleanContent);

      // A line can have multiple timestamps (repeated chorus).
      for (final tm in timeMatches) {
        final d = _toDuration(tm.group(1), tm.group(2), tm.group(3));
        if (d == null) continue;
        parsed.add(
          LyricLine(
            time: d,
            end: words.lastOrNull?.end,
            text: cleanContent,
            words: words,
          ),
        );
      }
    }

    if (!sawTimestamp) {
      // Pure plain text.
      return ParsedLyrics(
        synced: false,
        wordSynced: false,
        lines: const [],
        plainText: plainBuffer.where((l) => l.isNotEmpty).join('\n'),
      );
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));
    final alignedRomanization = _alignSupplements(parsed, romanization);
    final alignedRomanizationWords = _alignSupplements(
      parsed,
      romanizationWords,
    );
    final alignedTranslation = _alignSupplements(parsed, translation);

    final adjusted =
        offsetMs == 0 &&
            alignedRomanization.isEmpty &&
            alignedTranslation.isEmpty
        ? parsed
        : parsed.map((l) {
            final romanization = alignedRomanization[l.time.inMilliseconds];
            final words =
                alignedRomanizationWords[l.time.inMilliseconds] ??
                const <LyricWord>[];
            // Keep readable text when optional timings are incomplete or
            // belong to a different revision of the transliteration.
            final validWords =
                words.map((word) => word.text).join() == romanization
                ? words
                : const <LyricWord>[];
            return LyricLine(
              time: _shift(l.time, offsetMs),
              end: l.end == null ? null : _shift(l.end!, offsetMs),
              text: l.text,
              romanization: romanization,
              romanizationWords: _shiftWords(validWords, offsetMs),
              translation: alignedTranslation[l.time.inMilliseconds],
              words: _shiftWords(l.words, offsetMs),
            );
          }).toList();

    return ParsedLyrics(
      synced: true,
      wordSynced: sawWordTiming,
      lines: adjusted,
      plainText: plainBuffer.where((l) => l.isNotEmpty).join('\n'),
    );
  }

  /// Older files may have centisecond line times alongside millisecond
  /// supplement times. Resolve each supplement to one nearest line, keeping
  /// exact matches when multiple metadata entries compete for that line.
  static Map<int, T> _alignSupplements<T>(
    List<LyricLine> lines,
    Map<int, T> supplements,
  ) {
    final matched = <int, (int, T)>{};
    for (final entry in supplements.entries) {
      var lo = 0;
      var hi = lines.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (lines[mid].time.inMilliseconds < entry.key) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      int? nearest;
      var distance = 11;
      for (final index in [lo - 1, lo]) {
        if (index < 0 || index >= lines.length) continue;
        final time = lines[index].time.inMilliseconds;
        final delta = (time - entry.key).abs();
        if (delta < distance) {
          nearest = time;
          distance = delta;
        }
      }
      if (nearest == null) continue;
      final previous = matched[nearest];
      if (previous == null || distance < previous.$1) {
        matched[nearest] = (distance, entry.value);
      }
    }
    return matched.map((time, match) => MapEntry(time, match.$2));
  }

  static List<LyricWord> _parseRomanizationWords(String raw) {
    final value = jsonDecode(raw);
    if (value is! List) return const [];
    final words = <LyricWord>[];
    for (final item in value) {
      if (item case {
        'text': final String text,
        'startTimeMs': final int start,
        'endTimeMs': final int end,
      }) {
        if (text.trim().isEmpty ||
            start < 0 ||
            end < start ||
            (words.isNotEmpty && words.last.time.inMilliseconds > start)) {
          return const [];
        }
        words.add(
          LyricWord(
            time: Duration(milliseconds: start),
            end: Duration(milliseconds: end),
            text: text,
          ),
        );
      } else {
        return const [];
      }
    }
    return words;
  }

  static List<LyricWord> _shiftWords(List<LyricWord> words, int offsetMs) {
    if (offsetMs == 0 || words.isEmpty) return words;
    return words
        .map(
          (word) => LyricWord(
            time: _shift(word.time, offsetMs),
            end: word.end == null ? null : _shift(word.end!, offsetMs),
            text: word.text,
          ),
        )
        .toList(growable: false);
  }

  static Duration _shift(Duration d, int offsetMs) {
    // LRC offset: positive value shifts lyrics earlier.
    final ms = d.inMilliseconds - offsetMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  static List<LyricWord> _parseWords(String content) {
    final matches = _wordTimeTag.allMatches(content).toList();
    if (matches.isEmpty) return const [];

    final words = <LyricWord>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final d = _toDuration(m.group(1), m.group(2), m.group(3));
      if (d == null) continue;
      final start = m.end;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : content.length;
      final word = content.substring(start, end);
      if (word.trim().isEmpty) {
        final previous = words.lastOrNull;
        if (previous != null && previous.end == null && d >= previous.time) {
          words[words.length - 1] = LyricWord(
            time: previous.time,
            end: d,
            text: previous.text,
          );
        }
        continue;
      }
      words.add(LyricWord(time: d, text: word));
    }
    return words;
  }

  static ParsedLyrics? _parseTtml(String text) {
    try {
      final doc = XmlDocument.parse(text);
      final paragraphs = doc.findAllElements('p').toList();
      if (paragraphs.isEmpty) return null;

      final lines = <LyricLine>[];
      final plain = <String>[];
      var sawWords = false;

      for (final p in paragraphs) {
        final begin = _parseClock(p.getAttribute('begin'));
        final end = _parseClock(p.getAttribute('end'));

        // Word/syllable spans carry their own begin attribute.
        final spans = p.findElements('span').toList();
        final words = <LyricWord>[];
        if (spans.isNotEmpty) {
          for (final span in spans) {
            final sBegin = _parseClock(span.getAttribute('begin'));
            final spanText = span.innerText;
            if (sBegin != null && spanText.trim().isNotEmpty) {
              final sEnd = _parseClock(span.getAttribute('end'));
              words.add(
                LyricWord(
                  time: sBegin,
                  end: sEnd != null && sEnd >= sBegin ? sEnd : null,
                  text: '$spanText ',
                ),
              );
            }
          }
        }
        if (words.isNotEmpty) sawWords = true;

        final lineText = p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (lineText.isEmpty && words.isEmpty) continue;
        plain.add(lineText);

        if (begin != null) {
          lines.add(
            LyricLine(time: begin, end: end, text: lineText, words: words),
          );
        }
      }

      if (lines.isEmpty) {
        return ParsedLyrics(
          synced: false,
          wordSynced: false,
          lines: const [],
          plainText: plain.join('\n'),
        );
      }

      lines.sort((a, b) => a.time.compareTo(b.time));
      return ParsedLyrics(
        synced: true,
        wordSynced: sawWords,
        lines: lines,
        plainText: plain.where((l) => l.isNotEmpty).join('\n'),
      );
    } catch (_) {
      return null;
    }
  }

  // TTML clock value: "mm:ss.fff", "hh:mm:ss.fff" or "12.5s".
  static Duration? _parseClock(String? value) {
    if (value == null || value.isEmpty) return null;
    final v = value.trim();

    if (v.endsWith('s') && !v.contains(':')) {
      final seconds = double.tryParse(v.substring(0, v.length - 1));
      if (seconds == null) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    }

    final parts = v.split(':');
    try {
      if (parts.length == 3) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final s = double.parse(parts[2]);
        return Duration(hours: h, minutes: m, milliseconds: (s * 1000).round());
      } else if (parts.length == 2) {
        final m = int.parse(parts[0]);
        final s = double.parse(parts[1]);
        return Duration(minutes: m, milliseconds: (s * 1000).round());
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static int activeIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    var lo = 0;
    var hi = lines.length - 1;
    var result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }
}
