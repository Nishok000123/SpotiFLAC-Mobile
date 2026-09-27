import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Only verified native playback reports active. File metadata alone never does.
final usbAudioStatus = ValueNotifier<UsbAudioStatus>(const UsbAudioStatus());

class UsbAudioStatus {
  const UsbAudioStatus({
    this.reason = 'idle',
    this.device,
    this.sampleRate,
    this.bitDepth,
  });

  final String reason;
  final String? device;
  final int? sampleRate;
  final int? bitDepth;
}

/// Keeps the existing transport and AutoMix API while adding a local USB path.
/// Each prepare owns a token so delayed native events cannot affect a new song.
class MusicPlaybackDeck {
  MusicPlaybackDeck({required String playerId, bool? nativeAvailable})
    : _ordinary = AudioPlayer(playerId: playerId),
      _nativeAvailable = nativeAvailable ?? Platform.isAndroid {
    _subscriptions.addAll([
      _ordinary.onPlayerStateChanged.listen((value) {
        if (!_direct) _states.add(value);
      }),
      _ordinary.onDurationChanged.listen((value) {
        if (!_direct) _durations.add(value);
      }),
      _ordinary.onPlayerComplete.listen((_) {
        if (!_direct) _completions.add(null);
      }),
    ]);
  }

  static const _channel = MethodChannel('com.zarz.spotiflac/usb_pcm');
  static const _events = EventChannel('com.zarz.spotiflac/usb_pcm/events');
  static Stream<dynamic>? _nativeEvents;
  static int _nextToken = 0;
  final AudioPlayer _ordinary;
  final bool _nativeAvailable;
  final _states = StreamController<PlayerState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<dynamic>? _nativeSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _timer;
  bool _polling = false;
  bool _direct = false;
  bool _disposed = false;
  int _token = 0;
  Duration? _duration;
  DeviceFileSource? _source;
  bool _routeLost = false;
  bool _nativeStarted = false;
  PlayerState _directState = PlayerState.stopped;
  UsbAudioStatus _preparedStatus = const UsbAudioStatus();

  bool get isDirect => _direct;
  bool get needsSourceReload => _direct && _routeLost;
  PlayerState get state => _direct ? _directState : _ordinary.state;
  Stream<PlayerState> get onPlayerStateChanged => _states.stream;
  Stream<Duration> get onDurationChanged => _durations.stream;
  Stream<Duration> get onPositionChanged => _positions.stream;
  Stream<void> get onPlayerComplete => _completions.stream;

  set positionUpdater(PositionUpdater updater) {
    _ordinary.positionUpdater = updater;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = _ordinary.onPositionChanged.listen((value) {
      if (!_direct) _positions.add(value);
    });
  }

  Future<void> setReleaseMode(ReleaseMode mode) =>
      _ordinary.setReleaseMode(mode);
  Future<void> setAudioContext(AudioContext context) =>
      _ordinary.setAudioContext(context);
  Future<void> setVolume(double volume) async {
    if (!_direct) await _ordinary.setVolume(volume);
  }

  Future<void> setPlaybackRate(double rate) async {
    if (!_direct) await _ordinary.setPlaybackRate(rate);
  }

  Future<void> setSource(
    DeviceFileSource source, {
    bool preferBitPerfect = false,
  }) async {
    await stop();
    _source = source;
    _routeLost = false;
    _nativeStarted = false;
    if (preferBitPerfect && _nativeAvailable) {
      _token = ++_nextToken;
      _nativeSubscription ??=
          (_nativeEvents ??= _events.receiveBroadcastStream()).listen(
            _onNativeEvent,
            onError: (Object error) {
              if (_direct && !_disposed) {
                _routeLost = true;
                unawaited(pause().catchError((Object _) {}));
                usbAudioStatus.value = const UsbAudioStatus(
                  reason: 'route_changed',
                );
              }
            },
          );
      try {
        final response = await _channel.invokeMapMethod<String, dynamic>(
          'prepare',
          {'path': source.path, 'token': _token},
        );
        if (response?['ready'] == true) {
          _direct = true;
          _directState = PlayerState.stopped;
          _duration = Duration(
            milliseconds: (response?['duration'] as num?)?.toInt() ?? 0,
          );
          _preparedStatus = UsbAudioStatus(
            reason: 'active',
            device: response?['device'] as String?,
            sampleRate: (response?['sampleRate'] as num?)?.toInt(),
            bitDepth: (response?['bitDepth'] as num?)?.toInt(),
          );
          usbAudioStatus.value = const UsbAudioStatus(reason: 'ready');
          _durations.add(_duration!);
          return;
        }
        usbAudioStatus.value = UsbAudioStatus(
          reason: response?['reason'] as String? ?? 'unsupported',
        );
      } on PlatformException {
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      } on MissingPluginException {
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      }
    }
    await _ordinary.setSource(source);
  }

  void _onNativeEvent(dynamic event) {
    if (_disposed || !_direct || event is! Map || event['token'] != _token) {
      return;
    }
    switch (event['event']) {
      case 'active':
        usbAudioStatus.value = _preparedStatus;
      case 'paused':
        _routeLost = true;
        _timer?.cancel();
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
      case 'complete':
        _timer?.cancel();
        _setState(PlayerState.completed);
        _completions.add(null);
    }
  }

  void _setState(PlayerState value) {
    _directState = value;
    if (!_disposed) _states.add(value);
  }

  Future<void> resume() async {
    if (!_direct) return _ordinary.resume();
    final token = _token;
    // Before first playback the SAF lease is still open. After playback starts,
    // reconnect through the handler to obtain a fresh lease for the same song.
    try {
      if (_routeLost) throw PlatformException(code: 'route_changed');
      await _channel.invokeMethod<void>('resume');
    } on PlatformException {
      if (token != _token || !_direct || _disposed) return;
      if (_nativeStarted) {
        _routeLost = true;
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
        rethrow;
      }
      final source = _source;
      final position = await getCurrentPosition() ?? Duration.zero;
      await stop();
      usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      if (source == null || _disposed) return;
      await _ordinary.setVolume(1);
      await _ordinary.setSource(source);
      if (position > Duration.zero) await _ordinary.seek(position);
      return _ordinary.resume();
    }
    if (_disposed || token != _token || !_direct) return;
    _nativeStarted = true;
    _setState(PlayerState.playing);
    usbAudioStatus.value = _preparedStatus;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (_polling || _disposed) return;
      _polling = true;
      final token = _token;
      try {
        final position = await getCurrentPosition();
        if (!_disposed && _direct && token == _token && position != null) {
          _positions.add(position);
        }
      } on PlatformException {
        // Route failures arrive through the native event stream.
      } finally {
        _polling = false;
      }
    });
  }

  Future<void> pause() async {
    if (!_direct) return _ordinary.pause();
    final token = _token;
    _timer?.cancel();
    await _channel.invokeMethod<void>('pause');
    if (token == _token && _direct) _setState(PlayerState.paused);
  }

  Future<void> seek(Duration position) async {
    if (!_direct) return _ordinary.seek(position);
    final token = _token;
    await _channel.invokeMethod<void>('seek', {
      'position': position.inMilliseconds,
    });
    if (!_disposed && token == _token && _direct) _positions.add(position);
  }

  Future<Duration?> getCurrentPosition() async {
    if (!_direct) return _ordinary.getCurrentPosition();
    final milliseconds = await _channel.invokeMethod<int>('position');
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  Future<Duration?> getDuration() =>
      _direct ? Future.value(_duration) : _ordinary.getDuration();

  Future<void> stop() async {
    _timer?.cancel();
    if (_direct) {
      _token = ++_nextToken;
      await _channel.invokeMethod<void>('stop');
      _setState(PlayerState.stopped);
      _direct = false;
      usbAudioStatus.value = const UsbAudioStatus();
    }
    await _ordinary.stop();
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _nativeSubscription?.cancel();
    await _positionSubscription?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _ordinary.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
