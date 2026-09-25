import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/services/automix_analysis.dart';
import 'package:spotiflac_android/services/automix_analyzer.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/playback_notification.dart';

class _Analyzer extends AutoMixAnalyzer {
  final calls = <String>[];
  Completer<AutoMixBeatGrid?>? pending;
  bool matchBeats = false;

  @override
  Future<AutoMixBeatGrid?> analyze(String path, {double offset = 0}) async {
    calls.add(path);
    if (matchBeats) {
      return AutoMixBeatGrid(
        bpm: offset > 0 ? 120 : 124,
        phase: 0.17,
        confidence: 0.9,
        firstSound: 0.1,
      );
    }
    return pending?.future;
  }
}

/// Exercises the real AudioPlayer transport/streams against a native-channel
/// fake, including preparation, seek completion and outgoing completion events.
class _AudioNative {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <(String, String, Map<Object?, Object?>)>[];
  final positions = <String, int>{};
  final live = <String>{};
  final playing = <String>{};

  void install() {
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        final id = args['playerId']! as String;
        calls.add((id, call.method, args));
        switch (call.method) {
          case 'create':
            live.add(id);
            positions[id] = 0;
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          case 'setSourceUrl':
            unawaited(event(id, 'audio.onPrepared', true));
            unawaited(event(id, 'audio.onDuration', 60000));
          case 'seek':
            positions[id] = args['position']! as int;
            unawaited(event(id, 'audio.onSeekComplete'));
          case 'resume':
            playing.add(id);
          case 'pause' || 'stop':
            playing.remove(id);
          case 'dispose':
            playing.remove(id);
            live.remove(id);
          case 'getDuration':
            return 60000;
          case 'getCurrentPosition':
            return positions[id];
        }
        return null;
      },
    );
  }

  Future<void> event(String id, String name, [Object? value]) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        'value': ?value,
      }),
      (_) {},
    );
  }

  String get prepared => live.singleWhere((id) => id != 'music-player');

  double? lastVolume(String id) =>
      calls
              .where((call) => call.$1 == id && call.$2 == 'setVolume')
              .lastOrNull
              ?.$3['volume']
          as double?;
}

const _tracks = [
  PlayableMedia(id: 'one', source: '/one.flac', title: 'One', artist: 'Artist'),
  PlayableMedia(id: 'two', source: '/two.flac', title: 'Two', artist: 'Artist'),
  PlayableMedia(
    id: 'three',
    source: '/three.flac',
    title: 'Three',
    artist: 'Artist',
  ),
];

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Playback did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late _AudioNative native;
  late _Analyzer analyzer;
  late MusicPlayerHandler handler;

  setUp(() {
    setAutoMixEnabled(false);
    native = _AudioNative()..install();
    analyzer = _Analyzer();
    handler = MusicPlayerHandler(autoMixAnalyzer: analyzer);
  });

  tearDown(() async {
    await handler.dispose();
    configurePlaybackNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (_) async {},
    );
    analyzer.pending?.complete(null);
    setAutoMixEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(native.live, isEmpty);
    expect(native.playing, isEmpty);
  });

  test('Mornye notification follows theme and keeps transport state', () async {
    await handler.restoreSession(
      items: _tracks,
      index: 0,
      position: const Duration(seconds: 12),
      shuffle: false,
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        mornye: true,
        mediaId: 'one',
        source: '/one.flac',
        loved: true,
      ),
      toggleFavorite: (_) async {},
    );
    final state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.updatePosition, const Duration(seconds: 12));
    expect(state.controls.map((control) => control.action), [
      MediaAction.custom,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.skipToNext,
      MediaAction.custom,
    ]);
    expect(state.controls.first.androidIcon, contains('star_filled'));
    expect(state.androidCompactActionIndices, [1, 2, 3]);

    configurePlaybackNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (_) async {},
    );
    expect(handler.playbackState.value.controls, [
      MediaControl.skipToPrevious,
      MediaControl.play,
      MediaControl.skipToNext,
    ]);
    expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);
    expect(handler.playbackState.value.updatePosition, state.updatePosition);
    handler.playbackState.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 12),
        updateTime: DateTime.now().subtract(const Duration(seconds: 5)),
      ),
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(mornye: true),
      toggleFavorite: (_) async {},
    );
    expect(
      handler.playbackState.value.updatePosition.inMilliseconds,
      inInclusiveRange(17000, 17200),
      reason: 'Changing icons must not reset the live playback position',
    );
  });

  test(
    'notification favorite retains clicked track and ignores double taps',
    () async {
      final save = Completer<void>();
      final selected = <String>[];
      configurePlaybackNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          selected.add(item.id);
          await save.future;
        },
      );
      handler.mediaItem.add(_tracks.first.toMediaItem());
      final first = handler.customAction(PlaybackNotification.favoriteAction);
      handler.mediaItem.add(_tracks.last.toMediaItem());
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one']);
      save.complete();
      await first;
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one', 'three']);
    },
  );

  Future<void> prepare() async {
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.length == 2);
    await _until(
      () => native.calls.any((call) => call.$2 == 'setPlaybackRate'),
    );
  }

  Future<String> startMix({int startPosition = 55000}) async {
    await prepare();
    final incoming = native.prepared;
    native.positions['music-player'] = startPosition;
    await _until(() => handler.mediaItem.value?.id == 'two');
    await _until(() => (native.lastVolume(incoming) ?? 0) > 0);
    return incoming;
  }

  test(
    'disabled AutoMix uses only the ordinary player and no analysis',
    () async {
      await handler.setQueueAndPlay(_tracks);
      native.positions['music-player'] = 56000;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(analyzer.calls, isEmpty);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test(
    'handoff publishes native duration and ignores outgoing completion',
    () async {
      final incoming = await startMix();
      expect(native.playing, {'music-player', incoming});
      expect(handler.mediaItem.value?.duration, const Duration(minutes: 1));
      expect(handler.playbackState.value.queueIndex, 1);
      await native.event('music-player', 'audio.onComplete');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(handler.mediaItem.value?.id, 'two');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'pause during overlap stops both decks and restores incoming gain',
    () async {
      final incoming = await startMix();
      await handler.pause();
      expect(native.live, {incoming});
      expect(native.playing, isEmpty);
      expect(native.lastVolume(incoming), 1);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'matched transition releases outgoing and restores tempo after the fade',
    () async {
      analyzer.matchBeats = true;
      final incoming = await startMix(startPosition: 55670);
      expect(handler.playbackState.value.speed, closeTo(120 / 124, 0.0001));
      await Future<void>.delayed(const Duration(milliseconds: 4200));
      expect(native.live, {incoming});
      expect(native.lastVolume(incoming), closeTo(1, 0.0001));
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(handler.playbackState.value.speed, 1);
      expect(native.playing, {incoming});
      expect(
        native.calls.where(
          (call) => call.$1 == 'music-player' && call.$2 == 'dispose',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'seek during overlap cancels fade and seeks only the active deck',
    () async {
      final incoming = await startMix();
      await handler.seek(const Duration(seconds: 12));
      expect(native.live, {incoming});
      expect(native.positions[incoming], 12000);
      expect(native.lastVolume(incoming), 1);
    },
  );

  test(
    'turning AutoMix off releases the standby player without changing song',
    () async {
      await prepare();
      setAutoMixEnabled(false);
      await _until(() => native.live.length == 1);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
      expect(native.playing, {'music-player'});
    },
  );

  test('queue edit never starts the previously prepared next song', () async {
    await prepare();
    await handler.enqueue(_tracks[2], playNext: true);
    native.positions['music-player'] = 55000;
    await _until(() => analyzer.calls.length >= 4);
    await _until(() => handler.mediaItem.value?.id == 'three');
    expect(handler.mediaItem.value?.id, 'three');
  });

  test('manual skip invalidates an analysis still in flight', () async {
    analyzer.pending = Completer<AutoMixBeatGrid?>();
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.isNotEmpty);
    await handler.skipToNext();
    await handler.pause();
    analyzer.pending!.complete(null);
    analyzer.pending = null;
    await _until(() => native.live.length == 1);
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.playing, isEmpty);
  });

  test('repeat one never prepares another deck', () async {
    setAutoMixEnabled(true);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(native.live, {'music-player'});
    expect(analyzer.calls, isEmpty);
  });
}
