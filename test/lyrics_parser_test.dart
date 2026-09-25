import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

String _tag(String kind, int time, String text) =>
    '[x-$kind:$time:${base64.encode(utf8.encode(text))}]';

void main() {
  test(
    'writer tags and stored provider attribution remain separate from lyric rows',
    () {
      final lyrics = LyricsParser.parse('''
[au:Example Writer, Another Writer]
[by:SpotiFLAC-Mobile via Example Lyrics API (source: upstream)]
[00:01.00]First line
[00:04.00]Last line
''');
      expect(lyrics.writers, 'Example Writer, Another Writer');
      expect(lyrics.provider, 'Example Lyrics');
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines.last.time, const Duration(seconds: 4));
    },
  );

  test(
    'an LRC uploader or performing artist is not invented as the songwriter or provider',
    () {
      final lyrics = LyricsParser.parse(
        '[ar:Performer]\n[by:Uploader]\n[00:01.00]Line',
      );
      expect(lyrics.writers, isNull);
      expect(lyrics.provider, isNull);
      expect(
        LyricsParser.parse(
          '[by:SpotiFLAC-Mobile (source: extension:example.lyrics)]\n[00:01]Line',
        ).provider,
        'example.lyrics',
      );
    },
  );

  test(
    'explicit ending credits become a footer rather than a seekable lyric',
    () {
      final lyrics = LyricsParser.parse(
        '[00:01]Last lyric\n[00:04]Written By: Example Writer',
      );
      expect(lyrics.lines.single.text, 'Last lyric');
      expect(lyrics.writers, 'Example Writer');
      expect(lyrics.plainText, 'Last lyric');
    },
  );

  test(
    'TTML songwriter metadata is retained without treating performers as writers',
    () {
      final lyrics = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:meta="urn:example:metadata">
<head><metadata><meta:songwriters><meta:songwriter>Example Writer</meta:songwriter>
<meta:songwriter>Second Writer</meta:songwriter></meta:songwriters></metadata></head>
<body><div><p begin="00:01.00">Lyric</p></div></body></tt>
''');
      expect(lyrics.writers, 'Example Writer, Second Writer');
      expect(lyrics.lines.single.text, 'Lyric');
    },
  );

  test('retains all three texts, word ends and millisecond timing', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Romanized')}
${_tag('translation', 1009, 'English')}
[00:01.009]<00:01.009>First <00:01.307><00:02.003>second<00:02.497>
''');
    final line = lyrics.lines.single;
    expect(lyrics.wordSynced, isTrue);
    expect(line.text, 'First second');
    expect(line.romanization, 'Romanized');
    expect(line.translation, 'English');
    expect(line.time.inMilliseconds, 1009);
    expect(line.end?.inMilliseconds, 2497);
    expect(line.words.map((word) => word.end?.inMilliseconds), [1307, 2497]);
    expect(lyrics.plainText, 'First second');
  });

  test('matches legacy and rounded eLRC tags within ten milliseconds', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Rounded up')}
${_tag('translation', 2009, 'Truncated')}
${_tag('romaji', 2990, 'Boundary')}
${_tag('translation', 4011, 'Too far')}
[00:01.01]A
[00:02.00]B
[00:03.00]C
[00:04.00]D
''');
    expect(lyrics.lines[0].romanization, 'Rounded up');
    expect(lyrics.lines[1].translation, 'Truncated');
    expect(lyrics.lines[2].romanization, 'Boundary');
    expect(lyrics.lines[3].translation, isNull);
  });

  test(
    'romanization timing aligns with rounded lines and applies the offset',
    () {
      final words = [
        {'text': 'Ro', 'startTimeMs': 1009, 'endTimeMs': 1107},
        {'text': 'ma ', 'startTimeMs': 1107, 'endTimeMs': 1307},
        {'text': 'nized', 'startTimeMs': 2003, 'endTimeMs': 2497},
      ];
      final line = LyricsParser.parse('''
[offset:109]
${_tag('romaji-words', 1009, jsonEncode(words))}
${_tag('romaji', 1009, 'Roma nized')}
[00:01.01]Original
''').lines.single;
      expect(line.romanization, 'Roma nized');
      expect(line.romanizationWords.map((word) => word.text), [
        'Ro',
        'ma ',
        'nized',
      ]);
      expect(line.romanizationWords.first.time.inMilliseconds, 900);
      expect(line.romanizationWords[1].end?.inMilliseconds, 1198);
      expect(line.romanizationWords.last.time.inMilliseconds, 1894);
      expect(line.romanizationWords.last.end?.inMilliseconds, 2388);
    },
  );

  test(
    'missing or corrupt romanization timings preserve plain romanization',
    () {
      for (final timing in [
        'bad json',
        '{}',
        '[null]',
        '[{"text":"Other","startTimeMs":1000,"endTimeMs":1300}]',
        '[{"text":"Romanized","startTimeMs":1000,"endTimeMs":900}]',
      ]) {
        final line = LyricsParser.parse('''
${_tag('romaji', 1000, 'Romanized')}
${_tag('romaji-words', 1000, timing)}
[00:01.00]Original
''').lines.single;
        expect(line.romanization, 'Romanized');
        expect(line.romanizationWords, isEmpty);
      }
    },
  );

  test('exact matches win collisions and a tie goes to one earlier line', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Near')}
${_tag('romaji', 1010, 'Exact')}
${_tag('romaji', 1001, 'Further')}
${_tag('translation', 2005, 'Tie')}
[00:01.010]A
[00:02.000]B
[00:02.010]C
''');
    expect(lyrics.lines[0].romanization, 'Exact');
    expect(lyrics.lines[1].translation, 'Tie');
    expect(lyrics.lines[2].translation, isNull);
  });

  test('offset moves word ends and line end after supplement matching', () {
    final lyrics = LyricsParser.parse('''
[offset:109]
${_tag('romaji', 1009, 'Romanized')}
[00:01.009]<00:01.009>Word<00:01.307>
''');
    final line = lyrics.lines.single;
    expect(line.romanization, 'Romanized');
    expect(line.time.inMilliseconds, 900);
    expect(line.end?.inMilliseconds, 1198);
    expect(line.words.single.time.inMilliseconds, 900);
    expect(line.words.single.end?.inMilliseconds, 1198);
  });

  test('invalid optional tags do not appear or hide the original text', () {
    const tags = '''
[x-romaji:1000:%%%]
[x-romaji:1000:/w==]
[x-translation:bad:YQ==]
[x-translation:1000:]
''';
    expect(LyricsParser.parse(tags).isEmpty, isTrue);
    final lyrics = LyricsParser.parse('$tags[00:01.00]Original');
    expect(lyrics.lines.single.text, 'Original');
    expect(lyrics.lines.single.romanization, isNull);
    expect(lyrics.lines.single.translation, isNull);
    expect(lyrics.plainText, 'Original');
    expect(LyricsParser.parse('${tags}Plain text').plainText, 'Plain text');
  });

  test('supplement text safely retains Unicode and embedded newlines', () {
    const text = '日本語 ]\nSecond line';
    final lyrics = LyricsParser.parse(
      '${_tag('translation', 1000, text)}\n[00:01.00]Original',
    );
    expect(lyrics.lines.single.translation, text);
  });

  test('start-only eLRC retains its existing fallback timing', () {
    final line = LyricsParser.parse(
      '[00:01.00]<00:01.00>First <00:02.00>second',
    ).lines.single;
    expect(line.words.map((word) => word.end), [null, null]);
    expect(line.end, isNull);
  });

  test('empty tags retain the first valid end and reject backward ends', () {
    final line = LyricsParser.parse(
      '[00:01.00]<00:01.00>First <00:00.90><00:01.30><00:01.40>'
      '<00:02.00>second<00:02.00>',
    ).lines.single;
    expect(line.words.map((word) => word.end?.inMilliseconds), [1300, 2000]);
  });

  test('TTML span ends survive independently of the paragraph end', () {
    final line = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml"><body><div>
<p begin="00:01.009" end="00:05.000">
<span begin="00:01.009" end="00:01.307">First</span>
<span begin="00:02.003" end="00:02.497">second</span>
</p></div></body></tt>
''').lines.single;
    expect(line.end?.inMilliseconds, 5000);
    expect(line.words.map((word) => word.end?.inMilliseconds), [1307, 2497]);
  });
}
