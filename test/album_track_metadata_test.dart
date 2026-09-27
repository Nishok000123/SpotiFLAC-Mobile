import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/screens/album_screen.dart';
import 'package:spotiflac_android/screens/home_tab.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/album_description.dart';
import 'package:spotiflac_android/widgets/audio_quality_badges.dart';
import 'package:spotiflac_android/widgets/disc_separator_chip.dart';
import 'package:spotiflac_android/widgets/track_list_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.spotiflac/backend');
  final backendMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backendMessenger.setMockMethodCallHandler(
      backendChannel,
      (_) async => null,
    );
    await PlatformBridge.clearTrackCache();
  });
  tearDown(() async {
    backendMessenger.setMockMethodCallHandler(
      backendChannel,
      (_) async => null,
    );
    await PlatformBridge.clearTrackCache();
    backendMessenger.setMockMethodCallHandler(backendChannel, null);
  });

  for (final nested in [true, false]) {
    for (final fetchedName in ['Actual Album Title', '  ']) {
      testWidgets(
        'extension album resolves its title (nested: $nested, name: "$fetchedName")',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(const Size(430, 1200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const channel = MethodChannel('com.zarz.spotiflac/backend');
          final messenger = tester.binding.defaultBinaryMessenger;
          var requests = 0;
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'getProviderMetadata') return null;
            requests++;
            final info = <String, dynamic>{
              'name': fetchedName,
              'artists': 'Example Artist',
              'total_tracks': 1,
              'editorial_notes': {
                'standard': '<p>A <i>new direction</i> for the band.</p>',
                'short': 'A new direction.',
              },
            };
            final tracks = [
              {
                'id': 'example-song',
                'name': 'Example Song',
                'artists': 'Example Artist',
                'album_name': '',
                'duration_ms': 180000,
              },
            ];
            return jsonEncode(
              nested
                  ? {'album_info': info, 'track_list': tracks}
                  : {...info, 'tracks': tracks},
            );
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.light),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const ExtensionAlbumScreen(
                  extensionId: 'example-metadata',
                  albumId: 'example-album',
                  albumName: 'Album',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final expected = fetchedName.trim().isEmpty ? 'Album' : fetchedName;
          final album = tester.widget<AlbumScreen>(find.byType(AlbumScreen));
          expect(album.albumName, expected);
          expect(
            album.description,
            '<p>A <i>new direction</i> for the band.</p>',
          );
          expect(album.tracks!.single.albumName, expected);
          expect(find.text(expected), findsWidgets);
          expect(requests, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    for (final discs in [1, 2]) {
      testWidgets('online album disc groups (Mornye: $mornye, discs: $discs)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(430, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        backendMessenger.setMockMethodCallHandler(backendChannel, (call) async {
          if (call.method != 'getProviderMetadata') return null;
          return jsonEncode({
            'album_info': {'name': 'Example Album', 'total_tracks': 2},
            'track_list': [
              for (var index = 0; index < 2; index++)
                {
                  'id': 'song-$index',
                  'name': 'Song $index',
                  'artists': 'Example Artist',
                  'disc_number': index == 0 ? 1 : discs,
                  'total_discs': discs,
                  'track_number': discs == 1 ? index + 1 : 1,
                },
            ],
          });
        });
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ExtensionAlbumScreen(
                extensionId: 'example-metadata',
                albumId: 'disc-album-$mornye-$discs',
                albumName: 'Example Album',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tiles = tester.widgetList<TrackListTile>(
          find.byType(TrackListTile),
        );
        expect(tiles.map((tile) => tile.track.discNumber), [1, discs]);
        expect(tiles.map((tile) => tile.track.totalDiscs), [discs, discs]);
        expect(
          tiles.map((tile) => tile.track.trackNumber),
          discs == 1 ? [1, 2] : [1, 1],
        );
        if (discs == 1) {
          expect(find.byType(DiscSeparatorChip), findsNothing);
        } else {
          final headers = tester.widgetList<DiscSeparatorChip>(
            find.byType(DiscSeparatorChip),
          );
          expect(headers.map((header) => header.discNumber), [1, 2]);
          expect(
            tester.getTopLeft(find.text('Disc 2')).dy,
            inExclusiveRange(
              tester.getBottomLeft(find.text('Song 0')).dy,
              tester.getTopLeft(find.text('Song 1')).dy,
            ),
          );
          await tester.longPress(find.text('Song 1'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widgetList<TrackListTile>(find.byType(TrackListTile))
                .map((tile) => tile.isSelected),
            [false, true],
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('album tracks retain the extended tags supplied in search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('com.zarz.spotiflac/backend');
    const payload = <String, dynamic>{
      'id': 'song-1',
      'spotify_id': 'song-1',
      'name': 'Example Song',
      'artists': 'Example Artist',
      'album_name': 'Example Album',
      'duration_ms': 180000,
      'track_number': 1,
      'genre': 'Example Genre',
      'label': 'Example Label',
      'copyright': 'Example Copyright',
      'comment': 'Example Comment',
      'upc': '0123456789012',
      'audio_quality': '16-bit',
      'audio_modes': 'DOLBY_ATMOS',
      'explicit': true,
    };
    var albumRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getProviderMetadata') {
            expect(call.arguments, {
              'provider_id': 'example-metadata',
              'resource_type': 'album',
              'resource_id': 'metadata-album',
            });
            albumRequests++;
            return jsonEncode({
              'track_list': [payload],
              'album_info': {
                'name': 'Example Album',
                'total_tracks': 1,
                'album_type': 'album',
                'audio_traits': ['lossless', 'dolby_atmos'],
                'editorial_notes': {'standard': '<p>A new direction.</p>'},
              },
            });
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final searchTrack = Track.fromBackendMap(payload);
    expect(searchTrack.genre, 'Example Genre');
    expect(searchTrack.label, 'Example Label');
    expect(searchTrack.copyright, 'Example Copyright');

    final page = ProviderScope(
      child: MaterialApp(
        theme: MornyeTheme.build(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AlbumScreen(
          albumId: 'metadata-album',
          albumName: 'Example Album',
          extensionId: 'example-metadata',
        ),
      ),
    );
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(albumRequests, 1);
    expect(find.byType(AlbumDescription), findsOneWidget);
    final albumTrack = tester
        .widget<TrackListTile>(find.byType(TrackListTile).first)
        .track;
    expect(albumTrack.id, searchTrack.id);
    expect(albumTrack.name, searchTrack.name);
    expect(albumTrack.genre, searchTrack.genre);
    expect(albumTrack.label, searchTrack.label);
    expect(albumTrack.copyright, searchTrack.copyright);
    expect(albumTrack.comment, searchTrack.comment);
    expect(albumTrack.upc, searchTrack.upc);
    expect(albumTrack.albumId, 'metadata-album');
    expect(albumTrack.albumType, 'album');
    expect(albumTrack.totalTracks, 1);
    expect(albumTrack.audioQuality, '16-bit');
    expect(find.text('Lossless'), findsOneWidget);
    expect(find.text('Dolby Atmos'), findsNothing);
    expect(find.byTooltip('Dolby Atmos'), findsOneWidget);
    expect(find.byType(AudioQualityBadge), findsNothing);
    expect(find.byType(DolbyAtmosBadge), findsNothing);
    expect(find.byType(ExplicitBadge), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(albumRequests, 1);
    expect(
      tester
          .widget<AlbumDescription>(find.byType(AlbumDescription))
          .description,
      '<p>A new direction.</p>',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
