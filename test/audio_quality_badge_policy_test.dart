import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/audio_quality_badge_policy.dart';

void main() {
  group('Library audio quality badge color', () {
    test('keeps legacy 24-bit labels highlighted', () {
      expect(shouldHighlightAudioQualityBadge('24-bit/96kHz'), isTrue);
      expect(shouldHighlightAudioQualityBadge('FLAC 24bit-48kHz'), isTrue);
      expect(shouldHighlightAudioQualityBadge('24/192kHz'), isTrue);
    });

    test('highlights only measured bitrates above 900 kbps', () {
      expect(shouldHighlightAudioQualityBadge('900kbps'), isFalse);
      expect(shouldHighlightAudioQualityBadge('901kbps'), isTrue);
      expect(shouldHighlightAudioQualityBadge('FLAC 1760 kbps'), isTrue);
      expect(shouldHighlightAudioQualityBadge('1.76 Mbps'), isTrue);
    });

    test('leaves normal lossy bitrate labels neutral', () {
      expect(shouldHighlightAudioQualityBadge('AAC 320kbps'), isFalse);
      expect(shouldHighlightAudioQualityBadge('OPUS 256k'), isFalse);
      expect(shouldHighlightAudioQualityBadge('16-bit/44.1kHz'), isFalse);
    });
  });
}
