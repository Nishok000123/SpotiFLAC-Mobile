import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/extension_auth_launcher.dart';

void main() {
  test('extracts the extension that raised a verification challenge', () {
    expect(
      extensionIdFromVerificationError(
        "verification_required: extension 'tidal-web' needs verification",
        const ['amazon-web', 'tidal-web'],
      ),
      'tidal-web',
    );
  });

  test('prefers the longest known extension id in legacy errors', () {
    expect(
      extensionIdFromVerificationError(
        'qobuz-web verification_required',
        const ['qobuz', 'qobuz-web'],
      ),
      'qobuz-web',
    );
  });
}
