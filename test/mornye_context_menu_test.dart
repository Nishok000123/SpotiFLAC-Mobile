import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_context_menu.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openMenu(
    WidgetTester tester, {
    required Rect anchor,
    required ValueChanged<String?> onResult,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool reduceMotion = false,
    bool preferAbove = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reduceMotion,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    final result = await showMornyeContextMenu<String>(
                      context: context,
                      anchor: anchor,
                      preferAbove: preferAbove,
                      builder: (menuContext) {
                        MornyeMenuAction action(String label, IconData icon) =>
                            MornyeMenuAction(
                              icon: icon,
                              label: label,
                              onPressed: () =>
                                  Navigator.of(menuContext).pop(label),
                            );
                        return MornyeContextMenu(
                          quickActions: [
                            action(
                              'Download',
                              CupertinoIcons.arrow_down_circle,
                            ),
                            action('Favorite', CupertinoIcons.star),
                            action('Share', CupertinoIcons.share),
                          ],
                          groups: [
                            [
                              action('Play', CupertinoIcons.play),
                              action('Shuffle', CupertinoIcons.shuffle),
                            ],
                            [
                              action(
                                'Add to playlist',
                                CupertinoIcons.text_badge_plus,
                              ),
                              action('Play next', CupertinoIcons.text_insert),
                            ],
                            [action('Remove', CupertinoIcons.trash)],
                          ],
                        );
                      },
                    );
                    onResult(result);
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets('menu stays on screen near a bottom edge ($brightness)', (
      tester,
    ) async {
      String? result;
      const anchor = Rect.fromLTWH(338, 728, 36, 44);
      await openMenu(
        tester,
        anchor: anchor,
        brightness: brightness,
        onResult: (value) => result = value,
      );
      final rect = tester.getRect(find.byType(MornyeContextMenu));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(374));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThan(anchor.top));
      expect(find.text('Share').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(result, 'Share');
      expect(find.byType(MornyeContextMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'large text in landscape keeps shortcuts and last action usable',
    (tester) async {
      String? result;
      await openMenu(
        tester,
        anchor: const Rect.fromLTWH(600, 200, 24, 44),
        size: const Size(640, 320),
        textScale: 2.5,
        preferAbove: true,
        onResult: (value) => result = value,
      );
      final rect = tester.getRect(find.byType(MornyeContextMenu));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThanOrEqualTo(280));
      expect(find.text('Download').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(result, 'Remove');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('outside tap dismisses without selecting in reduced motion', (
    tester,
  ) async {
    final results = <String?>[];
    await openMenu(
      tester,
      anchor: const Rect.fromLTWH(12, 40, 44, 44),
      reduceMotion: true,
      preferAbove: true,
      onResult: results.add,
    );
    expect(
      tester.getRect(find.byType(MornyeContextMenu)).top,
      greaterThanOrEqualTo(84),
    );
    await tester.tapAt(const Offset(8, 800));
    await tester.pump();
    expect(results, [null]);
    expect(find.byType(MornyeContextMenu), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
