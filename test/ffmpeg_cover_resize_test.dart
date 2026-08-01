import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/ffmpeg_service.dart';

void main() {
  test('cover resize uses safe arguments and preserves aspect ratio', () {
    final arguments = FFmpegService.buildCoverResizeArguments(
      inputPath: '/tmp/input cover.jpg',
      outputPath: '/tmp/output cover.jpg',
      maxDimension: 1500,
    );

    expect(arguments, containsAllInOrder(['-i', '/tmp/input cover.jpg']));
    expect(
      arguments,
      containsAllInOrder([
        '-vf',
        'scale=1500:1500:force_original_aspect_ratio=decrease:flags=lanczos',
      ]),
    );
    expect(arguments, containsAllInOrder(['-frames:v', '1', '-update', '1']));
    expect(arguments.last, '/tmp/output cover.jpg');
  });

  test('cover resize rejects unreasonable dimensions', () {
    expect(
      () => FFmpegService.buildCoverResizeArguments(
        inputPath: 'input.jpg',
        outputPath: 'output.jpg',
        maxDimension: 0,
      ),
      throwsArgumentError,
    );
  });
}
