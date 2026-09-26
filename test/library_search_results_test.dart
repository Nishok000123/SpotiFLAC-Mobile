import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/providers/library_search_provider.dart';
import 'package:spotiflac_android/services/library_search.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/library_search_results.dart';

LibrarySearchHit _hit(
  LibrarySearchKind kind,
  int index, {
  String query = 'Found',
}) => LibrarySearchHit(
  kind: kind,
  id: '$index',
  title: '$query ${kind.name} $index',
);

void main() {
  for (final mornye in [false, true]) {
    testWidgets('Library shows every result type and paginates ($mornye)', (
      tester,
    ) async {
      final requests = <LibrarySearchRequest>[];
      final artists = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            librarySearchProvider.overrideWith((ref, request) async {
              requests.add(request);
              return List.generate(
                request.limit,
                (i) => _hit(request.kind, request.offset + i),
              );
            }),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  LibrarySearchResults(
                    query: 'Found',
                    onOpenArtist: artists.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests.map((r) => r.kind).toSet(),
        LibrarySearchKind.values.toSet(),
      );
      expect(requests.every((r) => r.limit == 6 && r.offset == 0), isTrue);
      await tester.tap(find.text('Artists').first);
      await tester.pumpAndSettle();
      expect(requests.last.limit, 41);
      await tester.tap(find.text('Found artists 0'));
      expect(artists, ['Found artists 0']);
      await tester.scrollUntilVisible(
        find.byIcon(Icons.expand_more),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(requests.last.offset, 40);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an older query cannot replace newer results', (tester) async {
    final old = Completer<List<LibrarySearchHit>>();
    late StateSetter update;
    var query = 'old';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          librarySearchProvider.overrideWith((ref, request) {
            if (request.kind != LibrarySearchKind.songs) {
              return Future.value([]);
            }
            return request.query == 'old'
                ? old.future
                : Future.value([_hit(request.kind, 0, query: request.query)]);
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: CustomScrollView(
                  slivers: [
                    LibrarySearchResults(query: query, onOpenArtist: (_) {}),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    update(() => query = 'new');
    await tester.pumpAndSettle();
    old.complete([_hit(LibrarySearchKind.songs, 0, query: 'old')]);
    await tester.pumpAndSettle();
    expect(find.text('new songs 0'), findsOneWidget);
    expect(find.text('old songs 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
