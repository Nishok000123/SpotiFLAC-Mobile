import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';
import 'package:spotiflac_android/utils/lyrics_timeline.dart';

void main() {
  List<(int, int)> gaps(String text) =>
      lyricsTimelineWithGaps(LyricsParser.parse(text).lines)
          .where((line) => line.text.isEmpty)
          .map((line) => (line.time.inMilliseconds, line.end!.inMilliseconds))
          .toList();

  test('intro and explicit LRC breaks count down, never the outro', () {
    const text = '''
[00:00.00]
[00:09.00]First
[00:12.00]
[00:14.00]
[00:21.00]Second
[00:25.00]
[00:30.00]
''';
    expect(gaps(text), [(0, 9000), (12000, 21000)]);
    expect(
      lyricsTimelineWithGaps(LyricsParser.parse(text).lines).last.text,
      'Second',
    );
  });

  test('TTML line ends identify breaks without empty timestamps', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="9s" end="12s">First</p>
<p begin="21s" end="24s">Second</p>
<p begin="25s" end="28s">Third</p>
</div></body></tt>
'''),
      [(0, 9000), (12000, 21000)],
    );
  });

  test('enhanced LRC word ends retain held vocals before a break', () {
    expect(
      gaps('''
[00:00.00]<00:00.00>Held<00:16.00>
[00:20.00]<00:20.00>Last<00:24.00>
'''),
      [(16000, 20000)],
    );
  });

  test('overlapping lines cannot start a countdown during a held vocal', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="16s">Held</p>
<p begin="8s" end="10s">Backing vocal</p>
<p begin="20s" end="24s">Last</p>
</div></body></tt>
'''),
      [(16000, 20000)],
    );
  });

  test('plain LRC does not invent an end time from distance between lines', () {
    expect(gaps('[00:00]Held\n[00:30]Last'), isEmpty);
    expect(gaps('[00:00]\n[00:30]'), isEmpty);
    expect(gaps('Unsynced text'), isEmpty);
  });

  test('short rests and immediate vocals have no flashing countdown', () {
    expect(gaps('[00:02]First\n[00:04]\n[00:06]Last'), isEmpty);
    expect(gaps('[00:00]First\n[00:04]\n[00:07]Last'), [(4000, 7000)]);
  });

  test('offset correction also moves the countdown boundaries', () {
    expect(gaps('[offset:500]\n[00:09]First\n[00:12]\n[00:21]Last'), [
      (0, 8500),
      (11500, 20500),
    ]);
  });

  test('word ends protect against an early or invalid paragraph end', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="2s"><span begin="0s" end="8s">Held</span></p>
<p begin="12s" end="14s">Last</p>
</div></body></tt>
'''),
      [(8000, 12000)],
    );
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="2s"><span begin="5s">Unknown end</span></p>
<p begin="12s" end="14s">Last</p>
</div></body></tt>
'''),
      isEmpty,
    );
  });
}
