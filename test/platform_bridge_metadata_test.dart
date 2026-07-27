import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.spotiflac/backend');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
  });

  test('display metadata uses the lightweight scan result directly', () async {
    final invokedMethods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          invokedMethods.add(call.method);
          if (call.method == 'readAudioMetadata') {
            return jsonEncode({
              'trackName': 'Song',
              'artistName': 'Artist',
              'bitDepth': 24,
              'sampleRate': 96000,
              'bitrate': 1800,
              'format': 'flac',
            });
          }
          fail('Unexpected full metadata read: ${call.method}');
        });

    final result = await PlatformBridge.readDisplayAudioMetadata(
      'content://downloads/song.flac',
    );

    expect(invokedMethods, ['readAudioMetadata']);
    expect(result['title'], 'Song');
    expect(result['artist'], 'Artist');
    expect(result['bit_depth'], 24);
    expect(result['sample_rate'], 96000);
    expect(result['audio_codec'], 'flac');
  });

  test(
    'display metadata falls back when scan only parsed the filename',
    () async {
      final invokedMethods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            invokedMethods.add(call.method);
            if (call.method == 'readAudioMetadata') {
              return jsonEncode({
                'trackName': 'Filename fallback',
                'metadataFromFilename': true,
                'format': 'flac',
              });
            }
            if (call.method == 'readFileMetadata') {
              return jsonEncode({
                'title': 'Embedded title',
                'audio_codec': 'opus',
              });
            }
            fail('Unexpected method: ${call.method}');
          });

      final result = await PlatformBridge.readDisplayAudioMetadata(
        'content://downloads/misnamed.flac',
      );

      expect(invokedMethods, ['readAudioMetadata', 'readFileMetadata']);
      expect(result['title'], 'Embedded title');
      expect(result['audio_codec'], 'opus');
    },
  );
}
