import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/library_browse_provider.dart';
import 'package:spotiflac_android/providers/library_search_provider.dart';
import 'package:spotiflac_android/screens/mornye_library_screen.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

LibraryBrowseEntry _album(int index) => LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album-$index',
  name: 'Album $index',
  artist: 'Artist $index',
  samplePath: '',
  trackCount: 1,
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Library separates browsing and downloads ($brightness)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <String>[];
      final requests = <LibraryBrowseRequest>[];
      final searches = <LibrarySearchRequest>[];
      final queue = DownloadQueueLookup.fromItems([
        for (final status in [DownloadStatus.queued, DownloadStatus.completed])
          DownloadItem(
            id: status.name,
            service: 'example',
            status: status,
            createdAt: DateTime(2026),
            track: Track(
              id: status.name,
              name: 'Track',
              artistName: 'Artist',
              albumName: 'Album',
              duration: 100,
            ),
          ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadQueueLookupProvider.overrideWithValue(queue),
            libraryBrowseProvider.overrideWith((ref, request) async {
              requests.add(request);
              return [_album(0), _album(1)];
            }),
            librarySearchProvider.overrideWith((ref, request) async {
              searches.add(request);
              return [];
            }),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(brightness),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MornyeLibraryScreen(onOpenSection: opened.add),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Songs'), findsOneWidget);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      await tester.tap(find.text('Downloads'));
      await tester.tap(find.text('Songs'));
      await tester.tap(find.text('Playlists'));
      expect(opened, ['downloads', 'all', 'playlists']);

      await tester.tap(find.byTooltip('Search your library'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'green lilac');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(searches, hasLength(4));
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(requests.last.artists, isTrue);
      await tester.tap(find.text('Artist 0'));
      await tester.pumpAndSettle();
      expect(requests.last.artists, isFalse);
      expect(requests.last.artist, 'Artist 0');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Library search is local and album pages load on scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <LibraryBrowseRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryBrowseProvider.overrideWith((ref, request) async {
            requests.add(request);
            return List.generate(request.limit, _album);
          }),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MornyeLibraryScreen(
              page: MornyeLibraryPage.albums,
              onOpenSection: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests.last.limit, 80);
    scroll.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search your library'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(TextField), 'My album');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(requests.last.search, 'My album');
    expect(requests.last.limit, 40);
    expect(tester.takeException(), isNull);
  });
}
