import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/player_motion_artwork_provider.dart';
import 'package:spotiflac_android/providers/player_artwork_video_provider.dart';
import 'package:spotiflac_android/services/motion_artwork_store.dart';
import 'package:video_player/video_player.dart';
import 'package:spotiflac_android/screens/now_playing_screen.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_volume_control.dart';
import 'package:spotiflac_android/widgets/lyric_gap_indicator.dart';
import 'package:spotiflac_android/widgets/mornye_player_queue.dart';
import 'package:spotiflac_android/widgets/mornye_playback_button.dart';
import 'package:spotiflac_android/widgets/mornye_playback_time.dart';
import 'package:spotiflac_android/widgets/mornye_player_actions_sheet.dart';
import 'package:spotiflac_android/widgets/mornye_player_favorite_button.dart';
import 'package:spotiflac_android/widgets/mornye_player_details_sheet.dart';
import 'package:spotiflac_android/widgets/mornye_metadata_row.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/mornye_player_background.dart';
import 'package:spotiflac_android/widgets/mornye_player_artwork.dart';
import 'package:spotiflac_android/widgets/mornye_artwork_contrast.dart';
import 'package:spotiflac_android/widgets/mini_player.dart';
import 'package:spotiflac_android/widgets/playback_seek_slider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.spotiflac/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late StreamController<MediaItem?> mediaItems;
  late List<double> volumeWrites;
  late Map<String, dynamic> metadataOverrides;
  late List<String> metadataReads;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mediaItems = StreamController<MediaItem?>.broadcast();
    volumeWrites = [];
    metadataOverrides = {};
    metadataReads = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          if (call.method != 'readFileMetadata') {
            fail('Unexpected platform call: ${call.method}');
          }
          final arguments = (call.arguments as Map).cast<String, dynamic>();
          final path = arguments['file_path']?.toString() ?? '';
          metadataReads.add(path);
          final lyrics = path.endsWith('/timed.flac')
              ? '''<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:00.000" end="00:02.000"><span begin="00:00.000">Short</span></p></div></body></tt>'''
              : path.endsWith('/many.flac')
              ? '[00:00.00]First line\n[00:02.00]Second line\n[00:04.00]Third line\n[00:06.00]Fourth line'
              : path.endsWith('/second.flac')
              ? '[00:01.00]Second lyric'
              : '[00:01.00]First lyric';
          return jsonEncode({
            'title': path.endsWith('/second.flac') ? 'Second' : 'First',
            'lyrics': lyrics,
            ...metadataOverrides,
          });
        });
  });

  tearDown(() async {
    await mediaItems.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  MediaItem item(String id) => MediaItem(
    id: id,
    title: id == 'first' ? 'First' : 'Second',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    extras: {'source': 'content://library/$id.flac'},
  );

  Future<void> pumpNowPlaying(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(1080, 1920),
    PlaybackState? playback,
    Stream<PlaybackState>? playbackEvents,
    Widget Function(Widget)? wrapPlayer,
    MotionArtwork? motionArtwork,
    MusicPlayerController? controller,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (controller != null)
            musicPlayerControllerProvider.overrideWithValue(controller),
          currentMediaItemProvider.overrideWith((ref) => mediaItems.stream),
          playerMotionArtworkProvider.overrideWith(
            (ref, album) async => motionArtwork,
          ),
          playerArtworkVideoProvider.overrideWith(
            (ref, source) => Completer<VideoPlayerController>().future,
          ),
          playerCollectionTrackProvider.overrideWith(
            (ref, item) async => Track(
              id: item.id,
              name: item.title,
              artistName: item.artist ?? '',
              albumName: item.album ?? '',
              duration: item.duration?.inSeconds ?? 0,
              source: 'local',
            ),
          ),
          libraryCollectionsProvider.overrideWith(_TestCollections.new),
          playbackStateProvider.overrideWith(
            (ref) =>
                playbackEvents ??
                (playback == null
                    ? const Stream.empty()
                    : Stream.value(playback)),
          ),
          playQueueProvider.overrideWith((ref) => const Stream.empty()),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          systemVolumeWriterProvider.overrideWith(
            (ref) =>
                (value) async => volumeWrites.add(value),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme,
          home:
              wrapPlayer?.call(const NowPlayingScreen()) ??
              const NowPlayingScreen(),
        ),
      ),
    );
  }

  testWidgets(
    'portrait motion cover keeps the raised square-cover control positions',
    (tester) async {
      Future<(double, double)> positions(MotionArtwork? artwork) async {
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          motionArtwork: artwork,
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        final title = tester.getTopLeft(find.text('First').hitTestable()).dy;
        final transport = tester
            .getCenter(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MornyePlaybackButton &&
                    widget.icon == CupertinoIcons.play_fill,
              ),
            )
            .dy;
        expect(title, lessThan(852 * 0.64));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        return (title, transport);
      }

      final square = await positions(null);
      final portrait = await positions(
        const MotionArtwork('file:///cover.mp4', aspectRatio: 0.75),
      );
      expect(portrait.$1, closeTo(square.$1, 1));
      expect(portrait.$2, closeTo(square.$2, 1));
    },
  );

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'static cover shrinks on pause without moving controls (reduced motion: $reducedMotion)',
      (tester) async {
        const longTitle =
            'I Do Not Want to Talk About It (A Long Album Version)';
        tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final playbackEvents = StreamController<PlaybackState>.broadcast();
        addTearDown(playbackEvents.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          playbackEvents: playbackEvents.stream,
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first').copyWith(title: longTitle));
        await tester.pumpAndSettle();
        playbackEvents.add(PlaybackState(playing: true));
        await tester.pumpAndSettle();

        final cover = find.byType(MornyePlayerArtwork);
        final playingCover = tester.getRect(cover);
        final titleFinder = find
            .text(longTitle)
            .hitTestable(at: Alignment.centerLeft)
            .first;
        final title = tester.getRect(titleFinder);
        final volume = tester.getRect(find.byType(MornyeVolumeControl));
        expect(playingCover.width, playingCover.height);
        expect(playingCover.width, greaterThanOrEqualTo(393 * 0.84));
        expect(playingCover.left, greaterThan(0));
        expect(playingCover.bottom, lessThan(title.top));
        expect(
          find.descendant(
            of: find.byType(MornyePlayerBackground),
            matching: cover,
          ),
          findsNothing,
        );

        playbackEvents.add(PlaybackState(playing: false));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        if (!reducedMotion) {
          expect(
            tester.getRect(cover).width,
            inExclusiveRange(playingCover.width * 0.73, playingCover.width),
          );
        }
        await tester.pumpAndSettle();
        final pausedCover = tester.getRect(cover);
        expect(pausedCover.width, closeTo(playingCover.width * 0.73, 0.01));
        expect(pausedCover.center.dx, closeTo(playingCover.center.dx, 0.01));
        expect(pausedCover.center.dy, closeTo(playingCover.center.dy, 0.01));
        expect(tester.getRect(titleFinder), title);
        expect(tester.getRect(find.byType(MornyeVolumeControl)), volume);

        playbackEvents.add(PlaybackState(playing: true));
        await tester.pumpAndSettle();
        expect(tester.getRect(cover).width, closeTo(playingCover.width, 0.01));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('video contrast updates controls without rebuilding artwork', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      motionArtwork: const MotionArtwork(
        'file:///cover.mp4',
        aspectRatio: 0.75,
      ),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    final background = tester.widget<MornyePlayerBackground>(
      find.byType(MornyePlayerBackground),
    );
    final title = find.text('First').hitTestable();
    final bounds = tester.getRect(title);
    final contrast = tester.widget<MornyeArtworkContrast>(
      find.byType(MornyeArtworkContrast),
    );
    for (final color in [Colors.black, Colors.white]) {
      contrast.onChanged({'header': color, 'controls': color, 'volume': color});
      await tester.pump();
      expect(
        tester.widget<MornyePlayerBackground>(
          find.byType(MornyePlayerBackground),
        ),
        same(background),
      );
      expect(tester.getRect(title), bounds);
      expect(
        tester
            .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
            .where(
              (button) => [
                CupertinoIcons.backward_fill,
                CupertinoIcons.play_fill,
                CupertinoIcons.forward_fill,
              ].contains(button.icon),
            )
            .map((button) => button.color),
        everyElement(color),
      );
      expect(
        tester
            .widget<MornyeVolumeControl>(find.byType(MornyeVolumeControl))
            .foreground,
        color,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Mornye lyrics keep wrapped, first and last lines at upper focus', (
    tester,
  ) async {
    final lyrics = List.generate(100, (index) {
      final seconds = index * 2;
      final time =
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
          '${(seconds % 60).toString().padLeft(2, '0')}.00';
      return '[$time]Line $index with enough words to wrap across several rows';
    }).join('\n');
    metadataOverrides = {'lyrics': lyrics};
    final playback = StreamController<PlaybackState>();
    addTearDown(playback.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playback.stream,
    );
    mediaItems.add(item('many'));
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 140)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();
    final current = find.text(
      'Line 70 with enough words to wrap across several rows',
    );
    expect(current, findsOneWidget);
    final list = find.byType(ListView);
    void expectUpperFocus(Finder line) {
      final bounds = tester.getRect(line);
      final viewport = tester.getRect(list);
      expect(bounds.top, closeTo(viewport.top + 16 + 780 * 0.06, 2));
    }

    expectUpperFocus(current);
    await tester.drag(list, const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();
    expectUpperFocus(current);
    for (final index in [99, 0]) {
      playback.add(PlaybackState(updatePosition: Duration(seconds: index * 2)));
      await tester.pumpAndSettle();
      expectUpperFocus(
        find.text('Line $index with enough words to wrap across several rows'),
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(393, 852), const Size(768, 1024)]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'slider scrubs lyrics both ways before seeking (size: $size, reduced motion: $reducedMotion)',
        (tester) async {
          metadataOverrides['lyrics'] = List.generate(
            18,
            (index) =>
                '[${(index ~/ 6).toString().padLeft(2, '0')}:'
                '${(index % 6 * 10).toString().padLeft(2, '0')}.00]'
                'Line $index with enough words to wrap across several rows',
          ).join('\n');
          final playback = StreamController<PlaybackState>.broadcast();
          addTearDown(playback.close);
          final controller = _SeekController();
          await pumpNowPlaying(
            tester,
            theme: MornyeTheme.build(Brightness.dark),
            size: size,
            playbackEvents: playback.stream,
            controller: controller,
            wrapPlayer: (player) => Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reducedMotion),
                child: player,
              ),
            ),
          );
          mediaItems.add(item('first'));
          playback.add(
            PlaybackState(updatePosition: const Duration(seconds: 1)),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
          await tester.pumpAndSettle();
          final slider = find.descendant(
            of: find.byType(PlaybackSeekSlider),
            matching: find.byType(Slider),
          );
          final bounds = tester.getRect(slider);
          Offset point(double fraction) => Offset(
            bounds.left + 8 + (bounds.width - 16) * fraction,
            bounds.center.dy,
          );
          final list = find.byType(ListView);
          double offset() => tester.widget<ListView>(list).controller!.offset;
          void expectFocus() {
            final seconds = tester.widget<Slider>(slider).value / 1000;
            final index = seconds ~/ 10;
            final line = find.text(
              'Line $index with enough words to wrap across several rows',
            );
            final focus = (size.height * 0.06).clamp(16, 48);
            expect(
              tester.getTopLeft(line).dy,
              closeTo(tester.getTopLeft(list).dy + focus + 16, 2),
            );
            final label = tester.widget<MornyePlaybackTime>(
              find.byKey(const ValueKey('elapsed:first')),
            );
            expect(label.seconds, seconds.floor());
          }

          final gesture = await tester.startGesture(point(0.02));
          await tester.pumpAndSettle();
          final initial = offset();
          await gesture.moveTo(point(0.82));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          final intermediate = offset();
          expect(intermediate, greaterThan(initial));
          await tester.pumpAndSettle();
          if (!reducedMotion) expect(offset(), greaterThan(intermediate));
          expectFocus();
          expect(controller.seeks, isEmpty);

          final forward = offset();
          await gesture.moveTo(point(0.19));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          expect(offset(), lessThan(forward));
          await tester.pumpAndSettle();
          expectFocus();
          final held = offset();
          // Neither playback ticks nor the automatic next-line timer may
          // move the user's preview while the finger is still down.
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              playing: true,
              updatePosition: const Duration(seconds: 151),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 10));
          expect(offset(), closeTo(held, 0.01));
          expectFocus();
          expect(controller.seeks, isEmpty);

          await gesture.up();
          await tester.pump();
          expect(controller.seeks, hasLength(1));
          playback.add(PlaybackState(updatePosition: controller.seeks.single));
          await tester.pump();
          controller.completions.single.complete();
          await tester.pumpAndSettle();
          expect(offset(), closeTo(held, 0.01));
          expectFocus();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('scrubbing previews word fills and instrumental dots exactly', (
    tester,
  ) async {
    metadataOverrides['lyrics'] = '''
<tt xmlns="http://www.w3.org/ns/ttml"><body><div>
<p begin="00:10.000" end="00:30.000"><span begin="00:10.000" end="00:20.000">First </span><span begin="00:20.000" end="00:30.000">second</span></p>
<p begin="00:40.000" end="00:50.000">Last vocal</p>
</div></body></tt>
''';
    final playback = StreamController<PlaybackState>.broadcast();
    addTearDown(playback.close);
    final controller = _SeekController();
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      playbackEvents: playback.stream,
      controller: controller,
    );
    mediaItems.add(item('first'));
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();
    final sliderFinder = find.descendant(
      of: find.byType(PlaybackSeekSlider),
      matching: find.byType(Slider),
    );
    Slider slider() => tester.widget<Slider>(sliderFinder);
    // Exact millisecond targets let this check word fills independently of
    // the gesture/scroll integration test above.
    slider().onChangeStart!(1000);
    Future<void> preview(int milliseconds) async {
      slider().onChanged!(milliseconds.toDouble());
      await tester.pumpAndSettle();
    }

    Future<List<int>> wordPixels() async {
      final paint = find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'First second',
        ),
        matching: find.byType(CustomPaint),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: paint, matching: find.byType(RepaintBoundary)).first,
      );
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final result = bytes.buffer.asUint8List().toList();
        image.dispose();
        return result;
      }))!;
    }

    await preview(15000);
    final firstWord = await wordPixels();
    await preview(25000);
    expect(await wordPixels(), isNot(firstWord));
    await preview(15000);
    expect(await wordPixels(), firstWord);
    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        updatePosition: const Duration(seconds: 45),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await wordPixels(), firstWord);

    for (final (milliseconds, alpha) in [(33333, 0.25), (36667, 1.0)]) {
      await preview(milliseconds);
      final dot = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('lyric-gap-dot-1')),
      );
      expect(
        (dot.decoration! as BoxDecoration).color!.a,
        closeTo(alpha, 0.001),
      );
    }
    await preview(170000);
    expect(find.byType(LyricGapIndicator), findsNothing);
    expect(controller.seeks, isEmpty);
    await preview(15000);
    slider().onChangeEnd!(15000);
    await tester.pump();
    expect(controller.seeks, [const Duration(seconds: 15)]);

    // A pending old seek must not leave the next track at the preview time.
    metadataOverrides['lyrics'] = '[00:02.00]New track start\n[00:14.00]Later';
    mediaItems.add(item('second'));
    playback.add(PlaybackState(updatePosition: Duration.zero));
    await tester.pumpAndSettle();
    expect(slider().value, 0);
    expect(find.text('New track start'), findsOneWidget);
    expect(find.byType(LyricGapIndicator), findsNothing);
    slider().onChangeStart!(0);
    await preview(35000);
    await preview(0);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.offset, 0);
    controller.completions.single.complete();
    await tester.pumpAndSettle();
    expect(slider().value, 0);
    expect(
      tester
          .widget<PlaybackSeekSlider>(find.byType(PlaybackSeekSlider))
          .preview!
          .value,
      Duration.zero,
    );
    slider().onChangeEnd!(0);
    controller.completions.last.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye landscape has no top handle or reserved toolbar height', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(
        Brightness.dark,
      ).copyWith(platform: TargetPlatform.android),
      size: const Size(900, 420),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.toolbarHeight, 0);
    expect(bar.title, isNull);
  });

  testWidgets('manual lyric scrolling hides controls down and restores them up', (
    tester,
  ) async {
    metadataOverrides = {
      'lyrics': List.generate(
        20,
        (index) =>
            '[00:${(index * 3).toString().padLeft(2, '0')}.00]Lyric $index with several words on this line',
      ).join('\n'),
    };
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playback: PlaybackState(updatePosition: const Duration(seconds: 30)),
    );
    mediaItems.add(item('many'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final initialHeight = tester.getSize(list).height;
    final headerTop = tester.getTopLeft(find.text('Second')).dy;
    final transport = find.byWidgetPredicate(
      (widget) =>
          widget is MornyePlaybackButton &&
          const [
            CupertinoIcons.play_fill,
            CupertinoIcons.backward_fill,
            CupertinoIcons.forward_fill,
          ].contains(widget.icon),
    );
    expect(transport.hitTestable(), findsNWidgets(3));
    await tester.drag(list, const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(tester.getSize(list).height, greaterThan(initialHeight + 100));
    expect(tester.getTopLeft(find.text('Second')).dy, closeTo(headerTop, 1));
    expect(transport.hitTestable(), findsNothing);
    await tester.drag(list, const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(tester.getSize(list).height, closeTo(initialHeight, 1));
    expect(transport.hitTestable(), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'lyrics hide controls after five idle seconds and restore on tap (reduced motion: $reducedMotion)',
      (tester) async {
        const lyric = 'First lyric with several words on this line';
        metadataOverrides['lyrics'] = '[00:00.00]$lyric\n[01:00.00]Second line';
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          playback: PlaybackState(playing: true),
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('many'));
        await tester.pumpAndSettle();
        final lyricsButton = find.byIcon(CupertinoIcons.quote_bubble);
        final queueButton = find.byIcon(CupertinoIcons.list_bullet);
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.pause_fill,
        );
        final volume = find.byType(MornyeVolumeControl);
        await tester.tap(lyricsButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(play.hitTestable(), findsOneWidget);
        final list = find.byType(ListView);
        final originalHeight = tester.getSize(list).height;
        final originalTop = tester.getTopLeft(find.text(lyric)).dy;
        await tester.pump(const Duration(milliseconds: 100));
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            tester.getTopLeft(find.text(lyric)).dy,
            closeTo(originalTop, 1),
          );
        }
        await tester.pumpAndSettle();
        expect(play.hitTestable(), findsNothing);
        expect(volume.hitTestable(), findsNothing);
        expect(lyricsButton.hitTestable(), findsNothing);
        expect(queueButton.hitTestable(), findsNothing);
        expect(tester.getSize(list).height, greaterThan(originalHeight + 150));
        expect(
          find.byKey(const ValueKey('player-track-header')).hitTestable(),
          findsOneWidget,
        );

        Future<void> reveal() async {
          final bounds = tester.getRect(list);
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 40));
            expect(
              tester.getTopLeft(find.text(lyric)).dy,
              closeTo(originalTop, 1),
            );
          }
          await tester.pumpAndSettle();
          expect(play.hitTestable(), findsOneWidget);
          expect(lyricsButton.hitTestable(), findsOneWidget);
        }

        await reveal();
        final slider = find.descendant(
          of: volume,
          matching: find.byType(Slider),
        );
        final touch = await tester.startGesture(tester.getCenter(slider));
        await tester.pump(const Duration(seconds: 5));
        expect(volume.hitTestable(), findsOneWidget);
        await touch.up();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(volume.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(volume.hitTestable(), findsNothing);

        await reveal();
        await tester.tap(queueButton.hitTestable());
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(play.hitTestable(), findsOneWidget);
        expect(queueButton.hitTestable(), findsOneWidget);
        await tester.tap(queueButton.hitTestable());
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(play.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'paused lyrics keep controls visible and resume gets five seconds (landscape: $landscape)',
      (tester) async {
        final playback = StreamController<PlaybackState>();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playbackEvents: playback.stream,
        );
        playback.add(PlaybackState(playing: false));
        mediaItems.add(item('many'));
        await tester.pumpAndSettle();
        final lyricsButton = find.byIcon(CupertinoIcons.quote_bubble);
        await tester.tap(lyricsButton);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(lyricsButton.hitTestable(), findsNothing);

        playback.add(PlaybackState(playing: false));
        await tester.pumpAndSettle();
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        // Pausing during the countdown must cancel the pending hide too.
        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        playback.add(PlaybackState(playing: false));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(lyricsButton.hitTestable(), findsOneWidget);

        playback.add(PlaybackState(playing: true));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 4900));
        expect(lyricsButton.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(lyricsButton.hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'accessible navigation keeps lyric controls available while idle',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        playback: PlaybackState(playing: true),
        wrapPlayer: (player) => Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: player,
          ),
        ),
      );
      mediaItems.add(item('many'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(MornyeVolumeControl).hitTestable(), findsOneWidget);
      expect(
        find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Mornye player background does not reveal the page below', (
    tester,
  ) async {
    final background = ValueNotifier<Color>(Colors.white);
    addTearDown(background.dispose);
    final capture = GlobalKey();
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.light),
      size: const Size(393, 780),
      wrapPlayer: (player) => RepaintBoundary(
        key: capture,
        child: ValueListenableBuilder<Color>(
          valueListenable: background,
          child: player,
          builder: (context, color, child) => Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: color),
              child!,
            ],
          ),
        ),
      ),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    Future<List<int>?> edgePixel() => tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (image.width + 1) * 4;
      final pixel = List<int>.generate(4, (i) => bytes.getUint8(offset + i));
      image.dispose();
      return pixel;
    });

    final onWhite = await edgePixel();
    background.value = Colors.red;
    await tester.pumpAndSettle();
    expect(await edgePixel(), onWhite);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye player menu floats above its button and retains dark colors',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      final moreButton = find.byIcon(CupertinoIcons.ellipsis).hitTestable();
      final anchor = tester.getRect(moreButton);
      await tester.tap(moreButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final panel = find.byType(MornyePlayerActionsSheet);
      final enteringWidth = tester.getSize(panel).width;
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).width, enteringWidth);
      expect(tester.getRect(panel).bottom, lessThan(anchor.top));
      expect(tester.getRect(panel).width, 320);
      expect(find.byType(BottomSheet), findsNothing);
      expect(Theme.of(tester.element(panel)).brightness, Brightness.dark);
      expect(
        tester.widget<Text>(find.text('Go to Album')).style?.color,
        Colors.white,
      );
      expect(find.byIcon(CupertinoIcons.square_stack), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.moon_zzz), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.gear_alt), findsNothing);
      expect(
        find.text(
          AppLocalizations.of(tester.element(panel)).collectionAddToPlaylist,
        ),
        findsOneWidget,
      );
      expect(find.text('Go to Artist'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Go to Album')).style?.fontSize, 15);
      await tester.ensureVisible(find.text('Sleep timer'));
      await tester.tap(find.text('Sleep timer'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('15 minutes'))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye title opens artist and album destinations with subtitles',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Go to Artist'), findsOneWidget);
      expect(find.text('Go to Album'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MornyePlayerNavigationMenu),
          matching: find.text('Artist'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(MornyePlayerNavigationMenu),
          matching: find.text('Album'),
        ),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(5, 770));
      await tester.pumpAndSettle();
      expect(find.byType(MornyePlayerNavigationMenu), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android Details reads full tags from a restored content URI', (
    tester,
  ) async {
    metadataOverrides = {
      'album_artist': 'Album Artist',
      'genre': 'Pop/Rock',
      'composer': 'Composer Name',
      'date': '2025-04-16',
      'track_number': 4,
    };
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(
        Brightness.dark,
      ).copyWith(platform: TargetPlatform.android),
      size: const Size(393, 852),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    expect(metadataReads, isEmpty);

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis).hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(metadataReads, ['content://library/first.flac']);
    final details = tester.widget<MornyePlayerDetailsSheet>(
      find.byType(MornyePlayerDetailsSheet),
    );
    expect(
      details.rows,
      containsAll([
        ('Title', 'First'),
        ('Album', 'Album'),
        ('Album Artist', 'Album Artist'),
        ('Genre', 'Pop/Rock'),
        ('Composer', 'Composer Name'),
        ('Date', '2025-04-16'),
        ('Track #', '4'),
      ]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye Details keeps long values readable and Done visible while scrolling',
    (tester) async {
      final rights = List.filled(10, 'A long copyright value').join(' ');
      metadataOverrides = {
        'title': 'First',
        'artist': 'Artist',
        'album': 'Album',
        'genre': 'Rock',
        'composer': 'Composer',
        'isrc': 'USAAA2600001',
        'copyright': rights,
        'format': 'flac',
        'sample_rate': 96000,
        'bit_depth': 24,
      };
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(
        item('first').copyWith(extras: {'source': '/library/first.flac'}),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      final sheet = find.byType(MornyePlayerDetailsSheet);
      expect(sheet, findsOneWidget);
      expect(Theme.of(tester.element(sheet)).brightness, Brightness.dark);
      expect(
        find.descendant(of: sheet, matching: find.byType(Card)),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.byType(MornyeGlass)),
        findsOneWidget,
      );
      final titleRow = find.widgetWithText(MornyeMetadataRow, 'Title');
      expect(
        tester
            .getTopLeft(
              find.descendant(of: titleRow, matching: find.text('First')),
            )
            .dy,
        greaterThan(tester.getBottomLeft(find.text('Title')).dy),
      );
      await tester.scrollUntilVisible(
        find.text(rights),
        200,
        scrollable: find.descendant(
          of: sheet,
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.getSize(find.text(rights)).height, greaterThan(40));
      expect(find.text('Done').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye star shares Library favorites across tracks and compact headers',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NowPlayingScreen)),
      );
      final star = find.byIcon(CupertinoIcons.star).hitTestable();
      expect(star, findsOneWidget);
      await tester.tap(star);
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );
      expect(
        container.read(libraryCollectionsProvider).loved.single.track.id,
        'first',
      );
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorited'));
      await tester.pumpAndSettle();
      expect(container.read(libraryCollectionsProvider).loved, isEmpty);
      expect(star, findsOneWidget);
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite'));
      await tester.pumpAndSettle();
      expect(
        container.read(libraryCollectionsProvider).loved.single.track.id,
        'first',
      );
      await tester.tap(find.byIcon(CupertinoIcons.list_bullet));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );
      mediaItems.add(item('second'));
      await tester.pumpAndSettle();
      expect(find.byIcon(CupertinoIcons.star).hitTestable(), findsOneWidget);
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.star_fill).hitTestable(),
        findsOneWidget,
      );

      // A change from Library must also update the player, without reopening it.
      final track = container
          .read(libraryCollectionsProvider)
          .loved
          .single
          .track;
      await container
          .read(libraryCollectionsProvider.notifier)
          .toggleLoved(track);
      await tester.pumpAndSettle();
      expect(find.byIcon(CupertinoIcons.star).hitTestable(), findsOneWidget);
      expect(
        find.byType(MornyePlayerFavoriteButton).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in ['material', 'portrait', 'landscape']) {
    testWidgets('instrumental dots follow intro, break and seeks ($layout)', (
      tester,
    ) async {
      metadataOverrides['lyrics'] = '''
[00:09.00]First vocal
[00:12.00]
[00:21.00]Last vocal
[00:25.00]
''';
      final playback = StreamController<PlaybackState>.broadcast();
      addTearDown(playback.close);
      await pumpNowPlaying(
        tester,
        theme: layout == 'material' ? null : MornyeTheme.build(Brightness.dark),
        size: layout == 'landscape'
            ? const Size(852, 393)
            : const Size(393, 852),
        playbackEvents: playback.stream,
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      if (layout == 'material') {
        await tester.drag(find.byType(PageView), const Offset(-350, 0));
      } else {
        await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      }
      await tester.pumpAndSettle();

      Future<void> positionAt(
        int seconds, {
        bool playing = false,
        AudioProcessingState state = AudioProcessingState.ready,
      }) async {
        playback.add(
          PlaybackState(
            processingState: state,
            playing: playing,
            updatePosition: Duration(seconds: seconds),
          ),
        );
        if (state == AudioProcessingState.ready) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }
      }

      List<double> dotAlphas() => List.generate(3, (index) {
        final dot = tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('lyric-gap-dot-$index')),
        );
        return (dot.decoration! as BoxDecoration).color!.a;
      });

      for (final (seconds, expected) in [
        (3, [1.0, 0.25, 0.25]),
        (6, [1.0, 1.0, 0.25]),
        (15, [1.0, 0.25, 0.25]),
        (18, [1.0, 1.0, 0.25]),
        (6, [1.0, 1.0, 0.25]),
      ]) {
        await positionAt(seconds);
        expect(find.byType(LyricGapIndicator).hitTestable(), findsOneWidget);
        expect(dotAlphas(), expected);
        if (layout != 'material') {
          final filter = tester.widget<ImageFiltered>(
            find
                .ancestor(
                  of: find.text(seconds >= 12 ? 'Last vocal' : 'First vocal'),
                  matching: find.byType(ImageFiltered),
                )
                .first,
          );
          expect(filter.enabled, isTrue);
        }
      }

      await positionAt(6, playing: true, state: AudioProcessingState.buffering);
      expect(find.byType(LyricGapIndicator), findsNothing);
      await positionAt(6);
      expect(dotAlphas(), [1.0, 1.0, 0.25]);
      await tester.pump(const Duration(seconds: 2));
      expect(dotAlphas(), [1.0, 1.0, 0.25]);

      for (final seconds in [9, 21, 25, 40]) {
        await positionAt(seconds);
        expect(find.byType(LyricGapIndicator), findsNothing);
      }
      await positionAt(6);
      expect(find.byType(LyricGapIndicator), findsOneWidget);
      metadataOverrides.clear();
      mediaItems.add(item('second'));
      await tester.pumpAndSettle();
      expect(find.byType(LyricGapIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye lyrics stay blurred until playback starts', (
    tester,
  ) async {
    final playback = StreamController<PlaybackState>();
    addTearDown(playback.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playback.stream,
    );
    mediaItems.add(item('many'));
    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.loading,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    void expectLine(String text, {required bool active}) {
      final line = find.text(text);
      final filter = tester.widget<ImageFiltered>(
        find.ancestor(of: line, matching: find.byType(ImageFiltered)).first,
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: line, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacity.opacity, active ? 1 : 0.48);
      expect(filter.enabled, !active, reason: '$text: ${filter.imageFilter}');
    }

    expectLine('First line', active: false);
    expectLine('Second line', active: false);
    expectLine('Third line', active: false);

    playback.add(PlaybackState(processingState: AudioProcessingState.ready));
    await tester.pumpAndSettle();
    expectLine('First line', active: false);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
    expectLine('First line', active: false);
    expectLine('Second line', active: true);
    expectLine('Third line', active: false);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pumpAndSettle();
    expectLine('Second line', active: true);

    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.buffering,
        playing: true,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
    expectLine('First line', active: false);
    expectLine('Second line', active: false);
    expectLine('Third line', active: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye lyrics keep the active line sharp with bold leading-aligned text',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
        playback: PlaybackState(updatePosition: const Duration(seconds: 2)),
      );
      mediaItems.add(item('many'));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      final active = find.text('Second line');
      final inactive = find.text('Third line');
      final activeText = tester.widget<Text>(active);
      expect(activeText.textAlign, TextAlign.start);
      expect(activeText.style?.fontWeight, FontWeight.bold);
      expect(activeText.style?.fontSize, 34);
      expect(tester.getTopLeft(active).dx, tester.getTopLeft(inactive).dx);
      expect(
        tester.getTopLeft(active).dx,
        tester.getTopLeft(find.byType(ListView)).dx + 24,
      );
      final activeFilters = tester.widgetList<ImageFiltered>(
        find.ancestor(of: active, matching: find.byType(ImageFiltered)),
      );
      expect(activeFilters.any((filter) => !filter.enabled), isTrue);
      final inactiveFilters = tester.widgetList<ImageFiltered>(
        find.ancestor(of: inactive, matching: find.byType(ImageFiltered)),
      );
      expect(
        inactiveFilters.any(
          (filter) =>
              filter.enabled &&
              filter.imageFilter == ImageFilter.blur(sigmaX: 2.4, sigmaY: 2.4),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye queue replaces artwork while volume and playback stay in place',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.light),
        size: const Size(393, 780),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.text('First lyric').hitTestable(), findsOneWidget);
      final volume = tester.getRect(find.byType(MornyeVolumeControl));
      await tester.tap(find.byIcon(CupertinoIcons.list_bullet));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.byType(MornyePlayerQueue), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.getRect(find.byType(MornyeVolumeControl)), volume);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(CupertinoIcons.list_bullet));
      await tester.pump();
      expect(find.text('First lyric'), findsNothing);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('First lyric'), findsNothing);
      expect(find.byType(MornyePlayerQueue), findsOneWidget);
      expect(find.byType(MornyePlayerQueue).hitTestable(), findsNothing);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.byType(MornyePlayerQueue), findsNothing);
      expect(tester.getRect(find.byType(MornyeVolumeControl)), volume);
    },
  );

  for (final landscape in [false, true]) {
    testWidgets(
      'paused play glyph is smaller without moving controls (landscape: $landscape)',
      (tester) async {
        final playback = StreamController<PlaybackState>();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(852, 393) : const Size(393, 852),
          playbackEvents: playback.stream,
        );
        playback.add(PlaybackState(playing: true));
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        final pause = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.pause_fill,
        );
        final pauseBounds = tester.getRect(pause);
        final pauseSize = tester.getSize(
          find.byIcon(CupertinoIcons.pause_fill),
        );
        final previous = find.byIcon(CupertinoIcons.backward_fill);
        final next = find.byIcon(CupertinoIcons.forward_fill);
        final previousBounds = tester.getRect(previous);
        final nextBounds = tester.getRect(next);
        final volumeBounds = tester.getRect(find.byType(MornyeVolumeControl));

        playback.add(PlaybackState(playing: false));
        await tester.pumpAndSettle();
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        final playSize = tester.getSize(find.byIcon(CupertinoIcons.play_fill));
        expect(playSize.width, lessThan(pauseSize.width));
        expect(playSize.width / pauseSize.width, inInclusiveRange(0.85, 0.95));
        expect(tester.getRect(play), pauseBounds);
        expect(tester.getRect(previous), previousBounds);
        expect(tester.getRect(next), nextBounds);
        expect(tester.getRect(find.byType(MornyeVolumeControl)), volumeBounds);

        playback.add(PlaybackState(playing: true));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byIcon(CupertinoIcons.pause_fill)),
          pauseSize,
        );
        expect(tester.getRect(pause), pauseBounds);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Mornye player renders Apple-style transport controls', (
    tester,
  ) async {
    await pumpNowPlaying(tester, theme: MornyeTheme.build(Brightness.light));
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.backward_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.forward_fill), findsOneWidget);
    expect(find.byType(MornyeVolumeControl), findsOneWidget);
    expect(tester.takeException(), isNull);

    final nextButton = find.widgetWithIcon(
      MornyePlaybackButton,
      CupertinoIcons.forward_fill,
    );
    final nextState = tester.state(nextButton);
    mediaItems.add(item('second'));
    await tester.pumpAndSettle();
    expect(tester.state(nextButton), same(nextState));
  });

  testWidgets('Mornye elapsed and remaining times roll on the same second', (
    tester,
  ) async {
    final playbackEvents = StreamController<PlaybackState>();
    addTearDown(playbackEvents.close);
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 780),
      playbackEvents: playbackEvents.stream,
    );
    mediaItems.add(
      item(
        'first',
      ).copyWith(duration: const Duration(seconds: 180, milliseconds: 600)),
    );

    Future<void> positionAt(int milliseconds) async {
      playbackEvents.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: false,
          updatePosition: Duration(milliseconds: milliseconds),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    final elapsed = find.byKey(const ValueKey('elapsed:first'));
    final remaining = find.byKey(const ValueKey('remaining:first'));
    void expectTimes(int elapsedSeconds, int remainingSeconds) {
      expect(
        tester.widget<MornyePlaybackTime>(elapsed).seconds,
        elapsedSeconds,
      );
      expect(
        tester.widget<MornyePlaybackTime>(remaining).seconds,
        remainingSeconds,
      );
    }

    await positionAt(34200);
    await tester.pumpAndSettle();
    expectTimes(34, 146);
    final transport = tester
        .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
        .toList();
    await positionAt(34800);
    expectTimes(34, 146);
    final updatedTransport = tester
        .widgetList<MornyePlaybackButton>(find.byType(MornyePlaybackButton))
        .toList();
    for (var i = 0; i < transport.length; i++) {
      expect(updatedTransport[i], same(transport[i]));
    }

    await positionAt(35000);
    await tester.pump(const Duration(milliseconds: 80));
    expectTimes(35, 145);
    double incomingOffset(Finder label) => tester
        .widget<SlideTransition>(
          find
              .ancestor(
                of: find.descendant(of: label, matching: find.text('5')),
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value
        .dy;
    expect(incomingOffset(elapsed), greaterThan(0));
    expect(incomingOffset(remaining), -incomingOffset(elapsed));

    // Another position report within this second must not restart either roll.
    await positionAt(35200);
    await tester.pump(const Duration(milliseconds: 200));
    expect(incomingOffset(elapsed), 0);
    expect(incomingOffset(remaining), 0);
    await positionAt(35900);
    expectTimes(35, 145);
    await positionAt(36000);
    expectTimes(36, 144);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye volume stays above the bottom actions on a phone', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 700),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    final volume = find.byType(MornyeVolumeControl);
    final lyricsButton = find.byIcon(CupertinoIcons.quote_bubble);
    final slider = find.descendant(of: volume, matching: find.byType(Slider));
    expect(
      tester.getRect(volume).bottom,
      lessThan(tester.getRect(lyricsButton).top),
    );
    expect(tester.getSize(slider).height, greaterThanOrEqualTo(44));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(volumeWrites, isNotEmpty);
    expect(volumeWrites.last, greaterThan(0.5));
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(volumeWrites, isNotEmpty);
    expect(volumeWrites.last, greaterThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mornye landscape opens the player and reveals hidden lyric actions on a bottom tap',
    (tester) async {
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        playback: PlaybackState(playing: true),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(852, 393);
      tester.view.padding = FakeViewPadding(left: 59, right: 59, bottom: 21);
      addTearDown(tester.view.resetPadding);
      await tester.pumpAndSettle();

      final artwork = find.byType(Hero);
      final volume = find.byType(MornyeVolumeControl);
      final artRect = tester.getRect(artwork);
      expect(artRect.width, closeTo(artRect.height, 0.1));
      expect(artRect.width, greaterThan(140));
      expect(artRect.top, greaterThanOrEqualTo(36));
      final header = find.text('First').hitTestable();
      final lyric = find.text('First lyric').hitTestable();
      expect(header, findsOneWidget);
      expect(lyric, findsNothing);
      expect(tester.getRect(header).left, greaterThan(artRect.right));
      expect(volume.hitTestable(), findsOneWidget);
      expect(
        find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      expect(
        find.byIcon(CupertinoIcons.pause_fill).hitTestable(),
        findsOneWidget,
      );
      final volumeSlider = find.descendant(
        of: volume,
        matching: find.byType(Slider),
      );
      final drag = await tester.startGesture(tester.getCenter(volumeSlider));
      await drag.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(seconds: 5));
      expect(volume.hitTestable(), findsOneWidget);
      expect(volumeWrites, isNotEmpty);
      await drag.up();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(volume.hitTestable(), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble).hitTestable());
      await tester.pumpAndSettle();
      expect(volume, findsNothing);
      expect(find.text('First lyric').hitTestable(), findsOneWidget);
      expect(tester.getRect(lyric).left, greaterThan(artRect.right));
      expect(
        tester.getRect(lyric).top,
        greaterThan(tester.getRect(header).bottom),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsNothing,
      );
      expect(
        find.byIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('landscape-actions-reveal')));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble).hitTestable());
      await tester.pumpAndSettle();
      expect(volume.hitTestable(), findsOneWidget);
      expect(lyric, findsNothing);
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble).hitTestable());
      await tester.pumpAndSettle();

      mediaItems.add(item('second'));
      await tester.pumpAndSettle();
      expect(find.text('Second lyric').hitTestable(), findsOneWidget);
      expect(find.text('First lyric'), findsNothing);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.resetPadding();
      await tester.pumpAndSettle();
      expect(
        find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byIcon(CupertinoIcons.list_bullet).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getRect(artwork).bottom,
        lessThan(tester.getRect(volume).top),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye motion cover stays attached throughout opening and closing',
    (tester) async {
      tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(393, 852),
        motionArtwork: const MotionArtwork('file:///cover.mp4', aspectRatio: 1),
        wrapPlayer: (_) => Consumer(
          builder: (context, ref, _) {
            ref.watch(currentMediaItemProvider);
            return Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(NowPlayingRoute()),
                  child: const Hero(
                    tag: kNowPlayingArtworkHeroTag,
                    child: SizedBox.square(dimension: 38, child: Text('Open')),
                  ),
                ),
              ),
            );
          },
        ),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pump();

      void expectAttached() {
        final panel = tester.getRect(find.byType(MornyePlayerBackground));
        final artwork = tester.getRect(
          find.descendant(
            of: find.byType(MornyePlayerBackground),
            matching: find.byType(MornyePlayerArtwork),
          ),
        );
        expect(artwork.left, closeTo(panel.left, 0.01));
        expect(artwork.top, closeTo(panel.top, 0.01));
        expect(artwork.width, closeTo(393, 0.01));
        expect(artwork.height, closeTo(393, 0.01));
      }

      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAttached();
      }
      await tester.pumpAndSettle();
      expectAttached();
      Navigator.of(tester.element(find.byType(NowPlayingScreen))).pop();
      await tester.pump();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAttached();
        expect(
          tester.getTopLeft(find.byType(MornyePlayerBackground)).dy,
          greaterThan(0),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final motion in [false, true]) {
    for (final drag in [false, true]) {
      testWidgets(
        'Mornye minimizes into the current mini player (motion: $motion, drag: $drag)',
        (tester) async {
          await pumpNowPlaying(
            tester,
            theme: MornyeTheme.build(Brightness.dark),
            size: const Size(393, 852),
            playback: PlaybackState(playing: true),
            motionArtwork: motion
                ? const MotionArtwork('file:///cover.mp4', aspectRatio: 1)
                : null,
            wrapPlayer: (_) => const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 90),
                  child: MiniPlayer(),
                ),
              ),
            ),
          );
          mediaItems.add(item('first'));
          await tester.pumpAndSettle();
          final mini = find.byType(MiniPlayer);
          final miniCover = find.descendant(
            of: mini,
            matching: find.byType(Hero),
          );
          final destination = tester.getRect(miniCover);
          await tester.tap(
            find.descendant(of: mini, matching: find.text('First')),
          );
          await tester.pumpAndSettle();
          final player = find.byType(NowPlayingScreen);
          final route =
              ModalRoute.of(tester.element(player))! as NowPlayingRoute;
          final fullCover = find.descendant(
            of: player,
            matching: find.byType(MornyePlayerArtwork),
          );
          if (drag) {
            route.startDrag();
            route.updateDrag(
              DragUpdateDetails(
                globalPosition: const Offset(0, 300),
                delta: const Offset(0, 300),
                primaryDelta: 300,
              ),
              852,
            );
            await tester.pump();
          }
          final releasedCover = tester.getRect(fullCover);
          final releasedPanel = tester.getRect(
            find.byType(MornyePlayerBackground),
          );
          if (drag) {
            route.endDrag(DragEndDetails(primaryVelocity: 0), 852);
          } else {
            Navigator.of(tester.element(player)).pop();
          }
          await tester.pump();
          final flyingCover = find.byKey(
            const ValueKey('player-minimize-artwork'),
          );
          final surface = find.byKey(const ValueKey('player-minimize-surface'));
          expect(tester.getRect(flyingCover), releasedCover);
          expect(tester.getRect(surface), releasedPanel);
          var previousDistance =
              (releasedCover.center - destination.center).distance;
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump(const Duration(milliseconds: 25));
            final bounds = tester.getRect(flyingCover);
            final distance = (bounds.center - destination.center).distance;
            expect(distance, lessThan(previousDistance));
            expect(
              bounds.width,
              inExclusiveRange(destination.width, releasedCover.width),
            );
            previousDistance = distance;
          }
          await tester.pumpAndSettle();
          expect(player, findsNothing);
          expect(tester.getRect(miniCover), destination);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final lyrics in [true, false]) {
    testWidgets(
      'motion cover moves into and expands out of ${lyrics ? 'lyrics' : 'queue'}',
      (tester) async {
        tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewPadding = FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
          motionArtwork: const MotionArtwork(
            'file:///cover.mp4',
            aspectRatio: 0.75,
          ),
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        final fullCover = find.descendant(
          of: find.byType(MornyePlayerBackground),
          matching: find.byType(MornyePlayerArtwork),
        );
        final fullBounds = tester.getRect(fullCover);
        final toggle = find.byIcon(
          lyrics ? CupertinoIcons.quote_bubble : CupertinoIcons.list_bullet,
        );
        final compact = find.byKey(const ValueKey('compact-player-artwork'));
        final playback = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        await tester.tap(toggle);
        await tester.pump();
        expect(tester.getRect(compact), fullBounds);
        var previous = fullBounds;
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final bounds = tester.getRect(compact);
          expect(bounds.width, lessThan(previous.width));
          expect(bounds.center.dy, lessThan(previous.center.dy));
          expect(playback.hitTestable(), findsOneWidget);
          previous = bounds;
        }
        await tester.pumpAndSettle();
        final compactBounds = tester.getRect(compact);
        expect(compactBounds.size, const Size(72, 72));
        final header = find.byKey(const ValueKey('player-track-header'));
        expect(tester.getRect(header).left, compactBounds.right + 12);
        expect(tester.getRect(header).center.dy, compactBounds.center.dy);
        await tester.tap(toggle);
        await tester.pump();
        expect(tester.getRect(compact), compactBounds);
        previous = compactBounds;
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 80));
          final bounds = tester.getRect(compact);
          expect(bounds.width, greaterThan(previous.width));
          expect(bounds.center.dy, greaterThan(previous.center.dy));
          expect(playback.hitTestable(), findsOneWidget);
          previous = bounds;
        }
        await tester.pumpAndSettle();
        expect(compact, findsNothing);
        expect(tester.getRect(fullCover), fullBounds);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'one header travels to and from ${lyrics ? 'lyrics' : 'queue'} beside the cover',
      (tester) async {
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(393, 852),
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        final toggle = find.byIcon(
          lyrics ? CupertinoIcons.quote_bubble : CupertinoIcons.list_bullet,
        );
        final header = find.byKey(const ValueKey('player-track-header'));
        final element = tester.element(header);
        final expandedBounds = tester.getRect(header);
        final play = find.widgetWithIcon(
          MornyePlaybackButton,
          CupertinoIcons.play_fill,
        );
        final controlsBounds = tester.getRect(play);
        final favorite = find.byType(MornyePlayerFavoriteButton);
        final favoriteState = tester.state(favorite);
        for (var visit = 0; visit < 2; visit++) {
          await tester.tap(toggle);
          await tester.pump();
          expect(tester.getRect(header), expandedBounds);
          var previous = expandedBounds;
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
            final bounds = tester.getRect(header);
            expect(bounds.top, lessThan(previous.top));
            expect(bounds.left, greaterThan(previous.left));
            expect(header.hitTestable(), findsOneWidget);
            expect(tester.element(header), same(element));
            expect(tester.state(favorite), same(favoriteState));
            expect(tester.getRect(play), controlsBounds);
            previous = bounds;
          }
          await tester.pumpAndSettle();
          final cover = tester.getRect(
            find.byKey(const ValueKey('compact-player-artwork')),
          );
          final compactBounds = tester.getRect(header);
          expect(compactBounds.left, cover.right + 12);
          expect(compactBounds.center.dy, cover.center.dy);
          await tester.tap(toggle);
          await tester.pump();
          expect(tester.getRect(header), compactBounds);
          previous = compactBounds;
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
            final bounds = tester.getRect(header);
            expect(bounds.top, greaterThan(previous.top));
            expect(bounds.left, lessThan(previous.left));
            expect(header.hitTestable(), findsOneWidget);
            expect(tester.element(header), same(element));
            expect(tester.state(favorite), same(favoriteState));
            expect(tester.getRect(play), controlsBounds);
            previous = bounds;
          }
          await tester.pumpAndSettle();
          expect(tester.getRect(header), expandedBounds);
          expect(
            find.byKey(const ValueKey('full-player-artwork')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('header reverses in place and stays beside cover across panels', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('player-track-header'));
    final element = tester.element(header);
    final expandedBounds = tester.getRect(header);
    final lyrics = find.byIcon(CupertinoIcons.quote_bubble);
    final queue = find.byIcon(CupertinoIcons.list_bullet);
    await tester.tap(lyrics);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final interruptedBounds = tester.getRect(header);
    await tester.tap(lyrics);
    await tester.pump();
    expect(tester.getRect(header), interruptedBounds);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(header).top, greaterThan(interruptedBounds.top));
    expect(tester.getRect(header).left, lessThan(interruptedBounds.left));
    await tester.pumpAndSettle();
    expect(tester.getRect(header), expandedBounds);

    await tester.tap(lyrics);
    await tester.pumpAndSettle();
    final compactBounds = tester.getRect(header);
    await tester.tap(queue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(header), compactBounds);
    expect(tester.element(header), same(element));
    await tester.pumpAndSettle();
    expect(tester.getRect(header), compactBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared header respects reduced motion and large text', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 852),
      wrapPlayer: (player) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: const TextScaler.linear(1.6),
          ),
          child: player,
        ),
      ),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('player-track-header'));
    final expandedBounds = tester.getRect(header);
    final lyrics = find.byIcon(CupertinoIcons.quote_bubble);
    await tester.tap(lyrics);
    await tester.pump();
    final compactBounds = tester.getRect(header);
    final cover = tester.getRect(
      find.byKey(const ValueKey('compact-player-artwork')),
    );
    expect(compactBounds.left, cover.right + 12);
    expect(compactBounds.top, cover.top);
    expect(compactBounds.top, lessThan(expandedBounds.top));
    await tester.tap(lyrics);
    await tester.pump();
    expect(tester.getRect(header), expandedBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye lyrics replace artwork while controls stay in place', (
    tester,
  ) async {
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(393, 700),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    final artwork = find.byType(Hero);
    final fullArtwork = tester.getRect(artwork);
    expect(fullArtwork.height, fullArtwork.width);
    final volume = find.byType(MornyeVolumeControl);
    final volumeRect = tester.getRect(volume);
    final play = find.byIcon(CupertinoIcons.play_fill);
    final playRect = tester.getRect(play);
    final lyricsButton = find.byIcon(CupertinoIcons.quote_bubble);
    await tester.tap(lyricsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final fullCover = find.byKey(const ValueKey('full-player-artwork'));
    double fullCoverOpacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(of: fullCover, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;
    expect(fullCover, findsOneWidget);
    expect(fullCoverOpacity(), inExclusiveRange(0.0, 1.0));
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsNothing);
    expect(find.text('First lyric').hitTestable(), findsOneWidget);
    expect(tester.getSize(artwork).width, lessThan(fullArtwork.width));
    expect(fullArtwork.top, greaterThan(0));
    expect(fullArtwork.width, lessThan(393));
    expect(tester.getRect(volume), volumeRect);
    expect(tester.getRect(play), playRect);

    mediaItems.add(item('second'));
    await tester.pumpAndSettle();
    expect(find.text('Second lyric').hitTestable(), findsOneWidget);
    expect(find.text('First lyric'), findsNothing);

    await tester.tap(lyricsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(fullCoverOpacity(), inExclusiveRange(0.0, 1.0));
    expect(
      find.descendant(of: fullCover, matching: find.byType(Hero)),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(artwork), fullArtwork);
    expect(find.text('Second lyric').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatic SAF track change refreshes lyrics while Lyrics page is active',
    (tester) async {
      await pumpNowPlaying(tester);

      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('First lyric'), findsOneWidget);

      mediaItems.add(item('second'));
      await tester.pumpAndSettle();

      expect(find.text('Second lyric'), findsOneWidget);
      expect(find.text('First lyric'), findsNothing);
    },
  );

  testWidgets(
    'lyrics end with writer and provider credits and clear them on track change',
    (tester) async {
      metadataOverrides['composer'] = 'Example Composer';
      metadataOverrides['lyrics'] =
          '[by:SpotiFLAC-Mobile via Example Lyrics API (source: upstream)]\n[00:01]Last lyric';
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      await tester.pumpAndSettle();
      final credit = find.text(
        'Written by: Example Composer\nLyrics: Example Lyrics',
      );
      expect(credit, findsOneWidget);
      expect(
        tester.getTopLeft(credit).dy,
        greaterThan(tester.getBottomLeft(find.text('Last lyric')).dy),
      );
      metadataOverrides.clear();
      mediaItems.add(item('second'));
      await tester.pumpAndSettle();
      expect(credit, findsNothing);
      expect(find.text('Second lyric'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final supplement in ['none', 'pronunciation', 'translation']) {
    testWidgets('language menu only offers available $supplement', (
      tester,
    ) async {
      metadataOverrides['lyrics'] =
          '${supplement == 'pronunciation' ? '[x-romaji:1009:${base64.encode(utf8.encode('Pronunciation'))}]\n' : ''}'
          '${supplement == 'translation' ? '[x-translation:1009:${base64.encode(utf8.encode('Translation'))}]\n' : ''}'
          '[00:01.009]Original';
      await pumpNowPlaying(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      await tester.pumpAndSettle();
      final options = find.byKey(const ValueKey('lyrics-language-options'));
      if (supplement == 'none') {
        expect(options, findsNothing);
      } else {
        await tester.tap(options);
        await tester.pumpAndSettle();
        final glass = tester.widget<MornyeGlassPanel>(
          find.byType(MornyeGlassPanel).last,
        );
        expect(glass.liquidGlass, isTrue);
        expect(glass.tintOpacity, lessThan(0.5));
        expect(
          find.text('Hide Pronunciation'),
          supplement == 'pronunciation' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Hide Translation'),
          supplement == 'translation' ? findsOneWidget : findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'language menu respects reduced motion and idle controls (landscape: $landscape)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Pronunciation'))}]\n'
            '[00:01.009]Original';
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: landscape ? const Size(844, 390) : const Size(390, 844),
          playback: PlaybackState(playing: true),
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
        await tester.pumpAndSettle();
        final options = find.byKey(const ValueKey('lyrics-language-options'));
        await tester.tap(options);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('Hide Pronunciation').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Hide Pronunciation'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Pronunciation'), findsNothing);
        expect(options.hitTestable(), findsOneWidget);

        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(options.hitTestable(), findsNothing);
        if (landscape) {
          await tester.tap(
            find.byKey(const ValueKey('landscape-actions-reveal')),
          );
        } else {
          final bounds = tester.getRect(find.byType(ListView));
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
        }
        await tester.pumpAndSettle();
        await tester.tap(options);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show Pronunciation'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Pronunciation'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('player shows original, romanization and English ($mornye)', (
      tester,
    ) async {
      metadataOverrides['lyrics'] =
          '[x-romaji:1009:${base64.encode(utf8.encode('Romanized text'))}]\n'
          '[x-translation:1009:${base64.encode(utf8.encode('English text'))}]\n'
          '[00:01.01]Original text';
      await pumpNowPlaying(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
        size: const Size(390, 844),
      );
      mediaItems.add(item('first'));
      await tester.pumpAndSettle();
      if (mornye) {
        await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
      } else {
        await tester.drag(find.byType(PageView), const Offset(-350, 0));
      }
      await tester.pumpAndSettle();
      for (final text in ['Original text', 'Romanized text', 'English text']) {
        expect(find.text(text), findsOneWidget);
      }
      if (mornye) {
        final pronunciation = tester.widget<Text>(find.text('Romanized text'));
        final translation = tester.widget<Text>(find.text('English text'));
        expect(pronunciation.style?.fontSize, 22);
        expect(pronunciation.style?.fontWeight, FontWeight.bold);
        expect(translation.style?.fontSize, 18);
      }
      expect(
        tester.getTopLeft(find.text('Romanized text')).dy,
        greaterThan(tester.getBottomLeft(find.text('Original text')).dy),
      );
      expect(
        tester.getTopLeft(find.text('English text')).dy,
        greaterThan(tester.getBottomLeft(find.text('Romanized text')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'lyric language toggles fade, resize and remember choices ($mornye)',
      (tester) async {
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Romanized text'))}]\n'
            '[x-translation:1009:${base64.encode(utf8.encode('English text'))}]\n'
            '[00:01.009]Original text\n[00:10.000]Next line';
        Future<void> openPlayer(String id) async {
          await pumpNowPlaying(
            tester,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
            size: const Size(390, 844),
            playback: PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: const Duration(milliseconds: 1500),
            ),
          );
          mediaItems.add(item(id));
          await tester.pumpAndSettle();
          if (mornye) {
            await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
          } else {
            await tester.drag(find.byType(PageView), const Offset(-350, 0));
          }
          await tester.pumpAndSettle();
        }

        final options = find.byKey(const ValueKey('lyrics-language-options'));
        Future<void> choose(String label) async {
          await tester.tap(options);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pump();
        }

        double gap() =>
            tester.getTopLeft(find.text('Next line')).dy -
            tester.getTopLeft(find.text('Original text')).dy;
        double pronunciationOpacity() => tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('Romanized text'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;

        await openPlayer('first');
        final expandedGap = gap();
        await choose('Hide Pronunciation');
        await tester.pump(const Duration(milliseconds: 100));
        expect(pronunciationOpacity(), inExclusiveRange(0, 1));
        final intermediateGap = gap();
        expect(intermediateGap, lessThan(expandedGap));
        await tester.pumpAndSettle();
        expect(find.text('Romanized text'), findsNothing);
        expect(find.text('English text'), findsOneWidget);
        expect(gap(), lessThan(intermediateGap));

        await choose('Show Pronunciation');
        await tester.pump(const Duration(milliseconds: 100));
        expect(pronunciationOpacity(), inExclusiveRange(0, 1));
        await tester.pumpAndSettle();
        expect(gap(), closeTo(expandedGap, 1));
        await choose('Hide Translation');
        await tester.pumpAndSettle();
        expect(find.text('English text'), findsNothing);
        expect(find.text('Romanized text'), findsOneWidget);
        await choose('Hide Pronunciation');
        await tester.pumpAndSettle();
        expect(find.text('Original text'), findsOneWidget);
        expect(find.text('Romanized text'), findsNothing);
        expect(options.hitTestable(), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await openPlayer('second');
        expect(find.text('English text'), findsNothing);
        expect(find.text('Romanized text'), findsNothing);
        await choose('Show Translation');
        await tester.pumpAndSettle();
        expect(find.text('English text'), findsOneWidget);
        expect(find.text('Romanized text'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'original and romanization follow word timing and pauses ($mornye)',
      (tester) async {
        final romanizationWords = base64.encode(
          utf8.encode(
            jsonEncode([
              {'text': 'Firsu ', 'startTimeMs': 1009, 'endTimeMs': 1307},
              {'text': 'secondu', 'startTimeMs': 2003, 'endTimeMs': 2497},
            ]),
          ),
        );
        metadataOverrides['lyrics'] =
            '[x-romaji:1009:${base64.encode(utf8.encode('Firsu secondu'))}]\n'
            '[x-romaji-words:1009:$romanizationWords]\n'
            '[00:01.009]<00:01.009>First <00:01.307>'
            '<00:02.003>second<00:02.497>';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          size: const Size(390, 844),
          playbackEvents: playback.stream,
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        if (mornye) {
          await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
        } else {
          await tester.drag(find.byType(PageView), const Offset(-350, 0));
        }
        await tester.pumpAndSettle();

        Future<List<int>> pixelsAt(int milliseconds, String text) async {
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              playing: false,
              updatePosition: Duration(milliseconds: milliseconds),
            ),
          );
          await tester.pumpAndSettle();
          final pixels = <int>[];
          for (final phrase in mornye ? text.split(' ') : [text]) {
            final paint = find.descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.label == phrase,
              ),
              matching: find.byType(CustomPaint),
            );
            expect(
              paint,
              findsOneWidget,
              reason: '$phrase at $milliseconds ms',
            );
            final painter = tester.widget<CustomPaint>(paint).painter!;
            final size = tester.getSize(paint);
            pixels.addAll(
              (await tester.runAsync(() async {
                final recorder = ui.PictureRecorder();
                painter.paint(Canvas(recorder), size);
                final picture = recorder.endRecording();
                final image = await picture.toImage(
                  size.width.ceil(),
                  size.height.ceil(),
                );
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final result = bytes.buffer.asUint8List().toList();
                image.dispose();
                picture.dispose();
                return result;
              }))!,
            );
          }
          return pixels;
        }

        for (final text in ['First second', 'Firsu secondu']) {
          final singingFirst = await pixelsAt(1100, text);
          final firstEnded = await pixelsAt(1307, text);
          expect(firstEnded, isNot(orderedEquals(singingFirst)));
          expect(await pixelsAt(1800, text), orderedEquals(firstEnded));
          final singingLast = await pixelsAt(2150, text);
          final lastEnded = await pixelsAt(2497, text);
          expect(lastEnded, isNot(orderedEquals(singingLast)));
          expect(await pixelsAt(2900, text), orderedEquals(lastEnded));
          expect(await pixelsAt(1100, text), orderedEquals(singingFirst));
        }
        final originalPixels = await pixelsAt(1100, 'First second');
        final options = find.byKey(const ValueKey('lyrics-language-options'));
        if (mornye && options.hitTestable().evaluate().isEmpty) {
          final bounds = tester.getRect(find.byType(ListView));
          await tester.tapAt(Offset(bounds.right - 6, bounds.top + 10));
          await tester.pumpAndSettle();
        }
        await tester.tap(options);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hide Pronunciation'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Firsu secondu'), findsNothing);
        expect(
          await pixelsAt(1100, 'First second'),
          orderedEquals(originalPixels),
        );
        await tester.tap(options);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show Pronunciation'));
        await tester.pumpAndSettle();
        await pixelsAt(2150, 'Firsu secondu');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'timed words lift and settle without moving layout (reduced motion: $reducedMotion)',
      (tester) async {
        const text = 'AAAA BBBB';
        metadataOverrides['lyrics'] =
            '[00:00.500]<00:01.000>AAAA <00:01.500>'
            '<00:03.000>BBBB<00:06.000>';
        final playback = StreamController<PlaybackState>.broadcast();
        addTearDown(playback.close);
        await pumpNowPlaying(
          tester,
          theme: MornyeTheme.build(Brightness.dark),
          size: const Size(390, 844),
          playbackEvents: playback.stream,
          wrapPlayer: (player) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: player,
            ),
          ),
        );
        mediaItems.add(item('first'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
        await tester.pumpAndSettle();
        final paintFinder = find.descendant(
          of: find.bySemanticsLabel(text),
          matching: find.byType(CustomPaint),
        );

        Future<(double, double)> paintedHeights() async {
          final painter = tester.widget<CustomPaint>(paintFinder).painter!;
          final size = tester.getSize(paintFinder);
          return (await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder)..translate(0, 8);
            painter.paint(canvas, size);
            final picture = recorder.endRecording();
            final image = await picture.toImage(
              size.width.ceil(),
              size.height.ceil() + 16,
            );
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            double centerFor(int from, int to) {
              var top = image.height;
              var bottom = -1;
              for (var y = 0; y < image.height; y++) {
                for (var x = from; x < to; x++) {
                  if (bytes.getUint8((y * image.width + x) * 4 + 3) < 16) {
                    continue;
                  }
                  if (y < top) top = y;
                  if (y > bottom) bottom = y;
                }
              }
              expect(bottom, greaterThan(top));
              return (top + bottom) / 2;
            }

            final result = (
              centerFor(0, (image.width * 0.4).floor()),
              centerFor((image.width * 0.6).ceil(), image.width),
            );
            image.dispose();
            picture.dispose();
            return result;
          }))!;
        }

        Future<(double, double)> seek(int milliseconds) async {
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: Duration(milliseconds: milliseconds),
            ),
          );
          await tester.pumpAndSettle();
          return paintedHeights();
        }

        final pending = await seek(800);
        final bounds = tester.getRect(paintFinder);
        final firstEnded = await seek(1600);
        expect(firstEnded.$2, pending.$2);
        if (reducedMotion) {
          expect(firstEnded, pending);
        } else {
          expect(pending.$1 - firstEnded.$1, inInclusiveRange(1, 2.5));
        }
        final held = await seek(4500);
        final settled = await seek(6000);
        expect(held.$1, firstEnded.$1);
        if (reducedMotion) {
          expect(held, pending);
          expect(settled, pending);
        } else {
          expect(settled.$2 - held.$2, greaterThan(1));
          expect(pending.$2 - settled.$2, inInclusiveRange(1, 2.5));
        }
        expect(tester.getRect(paintFinder), bounds);
        expect(await seek(4500), held);
        await tester.pump(const Duration(seconds: 1));
        expect(
          await paintedHeights(),
          held,
          reason: 'Paused words must stay still',
        );
        expect(await seek(800), pending);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('timed lyric fills text fragments in reading order', (
    tester,
  ) async {
    const lyricText = 'AAAA BBBB CCCC DDDD EEEE FFFF GGGG HHHH';
    metadataOverrides['lyrics'] =
        '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
        '<p begin="00:00.000" end="00:08.000">'
        '<span begin="00:00.000">$lyricText</span>'
        '</p></div></body></tt>';
    await pumpNowPlaying(
      tester,
      theme: MornyeTheme.build(Brightness.dark),
      size: const Size(320, 844),
      playback: PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: false,
        updatePosition: const Duration(seconds: 2),
      ),
    );
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.quote_bubble));
    await tester.pumpAndSettle();

    final paintFinder = find.descendant(
      of: find.bySemanticsLabel(lyricText),
      matching: find.byType(CustomPaint),
    );
    final painter = tester.widget<CustomPaint>(paintFinder).painter!;
    final size = tester.getSize(paintFinder);
    final highlightedPixels = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.ceil(),
        size.height.ceil(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var upper = 0;
      var lower = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (bytes.getUint8((y * image.width + x) * 4 + 3) < 230) continue;
          if (y < image.height ~/ 2) {
            upper++;
          } else {
            lower++;
          }
        }
      }
      image.dispose();
      picture.dispose();
      return (upper, lower);
    });
    expect(highlightedPixels!.$1, greaterThan(0));
    expect(highlightedPixels.$2, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short timed lyric remains horizontally centered', (
    tester,
  ) async {
    await pumpNowPlaying(tester);

    mediaItems.add(item('timed'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();

    final lyric = find.bySemanticsLabel('Short');
    expect(lyric, findsOneWidget);
    expect(tester.getCenter(lyric).dx, closeTo(540, 1));
  });

  testWidgets('Now Playing menu exposes Go to Album when album is known', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Go to Album'), findsOneWidget);
    expect(find.byIcon(Icons.album_outlined), findsOneWidget);
  });

  testWidgets('Now Playing menu exposes sleep timer duration choices', (
    tester,
  ) async {
    await pumpNowPlaying(tester);
    mediaItems.add(item('first'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sleep timer'));
    await tester.pumpAndSettle();

    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.text('30 minutes'), findsOneWidget);
    expect(find.text('45 minutes'), findsOneWidget);
    expect(find.text('60 minutes'), findsOneWidget);
    expect(find.text('Turn off sleep timer'), findsNothing);
  });
}

class _SeekController extends MusicPlayerController {
  final seeks = <Duration>[];
  final completions = <Completer<void>>[];

  @override
  Future<void> seek(Duration position) {
    seeks.add(position);
    final completion = Completer<void>();
    completions.add(completion);
    return completion.future;
  }
}

class _TestCollections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<bool> toggleLoved(Track track) async {
    final key = trackCollectionKey(track);
    final added = !state.isLoved(track);
    state = state.copyWith(
      loved: added
          ? [
              ...state.loved,
              CollectionTrackEntry(
                key: key,
                track: track,
                addedAt: DateTime.now(),
              ),
            ]
          : state.loved.where((entry) => entry.key != key).toList(),
    );
    return added;
  }
}
