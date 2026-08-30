import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spotiflac_android/services/backup_service.dart';

void main() {
  test('ZIP v2 pages history and streams cover files during restore', () async {
    final root = await Directory.systemTemp.createTemp(
      'spotiflac-backup-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final output = await Directory(p.join(root.path, 'output')).create();
    final temporary = await Directory(p.join(root.path, 'temporary')).create();
    final cover = File(p.join(root.path, 'cover.jpg'));
    await cover.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
    final history = List.generate(
      1203,
      (index) => <String, dynamic>{'id': 'item-$index', 'value': index},
    );
    final offsets = <int>[];

    final file = await BackupService.writeBackupArchive(
      settings: const {'theme': 'dark'},
      loadHistoryPage: (limit, offset) async {
        offsets.add(offset);
        if (offset >= history.length) {
          return const <Map<String, dynamic>>[];
        }
        final end = (offset + limit).clamp(0, history.length);
        return history.sublist(offset, end);
      },
      collections: const {
        'loved': <dynamic>[],
        'wishlist': <dynamic>[],
        'playlists': <dynamic>[],
      },
      playlistCoverFiles: {
        'playlist-1': {'ext': '.jpg', 'path': cover.path},
      },
      extensions: const {'items': <dynamic>[]},
      outputDirectory: output,
      temporaryDirectory: temporary,
    );

    expect(file.path, endsWith('.${BackupService.fileExtension}'));
    expect(offsets, [0, 500, 1000]);
    final bundle = await BackupService.parseFile(
      file.path,
      temporaryDirectory: temporary,
    );
    expect(bundle, isNotNull);
    expect(bundle!.formatVersion, 2);
    expect(bundle.historyCount, history.length);
    final restoredHistory = await bundle.streamHistory().toList();
    expect(restoredHistory, hasLength(history.length));
    expect(restoredHistory.last['id'], 'item-1202');
    final restoredCover = bundle.playlistCovers['playlist-1'];
    expect(restoredCover, isA<Map<String, dynamic>>());
    final restoredCoverPath =
        (restoredCover as Map<String, dynamic>)['path'] as String;
    expect(await File(restoredCoverPath).readAsBytes(), [
      0xff,
      0xd8,
      0xff,
      0xd9,
    ]);

    await bundle.cleanup();
    expect(await File(restoredCoverPath).exists(), isFalse);
  });
}
