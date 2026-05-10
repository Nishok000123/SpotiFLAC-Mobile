import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('M3uExportService');

class M3uExportService {
  /// Generates an M3U playlist from the given download history items and shares
  /// it via the system share sheet. Returns true on success.
  static Future<bool> exportAndShare(
    List<DownloadHistoryItem> items,
  ) async {
    if (items.isEmpty) return false;

    final buffer = StringBuffer();
    buffer.writeln('#EXTM3U');
    for (final item in items) {
      final duration = item.duration ?? -1;
      buffer.writeln(
        '#EXTINF:$duration,${item.artistName} - ${item.trackName}',
      );
      buffer.writeln(item.filePath);
    }

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/SpotiFLAC_Library.m3u');
      await file.writeAsString(buffer.toString(), flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'audio/x-mpegurl')],
        subject: 'SpotiFLAC Library Playlist',
      );
      return true;
    } catch (e, stack) {
      _log.e('M3U export failed: $e', e, stack);
      return false;
    }
  }
}
