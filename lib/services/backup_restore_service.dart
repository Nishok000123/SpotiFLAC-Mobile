import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('BackupRestoreService');
const _backupVersion = 1;
const _supportedBackupVersions = {_backupVersion};

class BackupRestoreService {
  /// Exports [settings] to a JSON file and shares it via the system share sheet.
  static Future<bool> exportSettings(AppSettings settings) async {
    try {
      final payload = {
        'backup_version': _backupVersion,
        'exported_at': DateTime.now().toIso8601String(),
        'settings': settings.toJson(),
      };
      final json = const JsonEncoder.withIndent('  ').convert(payload);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/SpotiFLAC_settings_backup.json');
      await file.writeAsString(json, flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'SpotiFLAC Settings Backup',
      );
      return true;
    } catch (e, stack) {
      _log.e('Settings export failed: $e', e, stack);
      return false;
    }
  }

  /// Opens a file picker, reads the chosen JSON file and returns the decoded
  /// [AppSettings]. Returns null if the user cancelled or the file is invalid.
  static Future<AppSettings?> importSettings() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.single.path == null) return null;
      final content = await File(result.files.single.path!).readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final backupVersion = decoded['backup_version'];
      if (backupVersion is num &&
          !_supportedBackupVersions.contains(backupVersion.toInt())) {
        _log.w('Unsupported backup version: ${backupVersion.toInt()}');
        return null;
      }
      final settingsJson = decoded['settings'];
      if (settingsJson is! Map) return null;
      return AppSettings.fromJson(Map<String, dynamic>.from(settingsJson));
    } catch (e, stack) {
      _log.e('Settings import failed: $e', e, stack);
      return null;
    }
  }
}
