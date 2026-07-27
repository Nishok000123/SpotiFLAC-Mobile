import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/level.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

part 'audio_analysis_models.dart';
part 'audio_analysis_info_card.dart';
part 'audio_analysis_spectrogram.dart';

const int audioSpectrogramWidth = 1600;
const int audioSpectrogramHeight = 800;
const double audioSpectrogramDynamicRangeDb = 120;

String buildAudioSpectrogramFilter({int channel = -1}) {
  final channelFilter = channel >= 0 ? 'pan=mono|c0=c$channel,' : '';
  return '[0:a:0]${channelFilter}aformat=sample_fmts=fltp,'
      'showspectrumpic='
      's=${audioSpectrogramWidth}x$audioSpectrogramHeight:'
      'legend=0:mode=combined:color=intensity:scale=log:fscale=lin:'
      'win_func=hann:drange=${audioSpectrogramDynamicRangeDb.toStringAsFixed(0)}:'
      'limit=0,format=rgba[spectrum]';
}

List<String> buildAudioSpectrogramArguments({
  required String inputPath,
  required String outputPath,
  int channel = -1,
}) {
  return [
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    inputPath,
    '-filter_complex',
    buildAudioSpectrogramFilter(channel: channel),
    '-map',
    '[spectrum]',
    '-frames:v',
    '1',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgba',
    '-y',
    outputPath,
  ];
}

class AudioAstatsSummary {
  final double peakDb;
  final double rmsDb;

  const AudioAstatsSummary({required this.peakDb, required this.rmsDb});
}

AudioAstatsSummary? parseAudioAstatsSummary(String logs) {
  final overallMatch = RegExp(r'Overall([\s\S]*)').firstMatch(logs);
  final section = overallMatch?.group(1) ?? logs;
  final peak = _parseLastAudioAstatsValue(section, 'Peak level dB');
  final rms = _parseLastAudioAstatsValue(section, 'RMS level dB');
  if (peak == null || rms == null) return null;
  return AudioAstatsSummary(peakDb: peak, rmsDb: rms);
}

double? _parseLastAudioAstatsValue(String text, String label) {
  final matches = RegExp(
    '${RegExp.escape(label)}:\\s*([-+]?\\d+(?:\\.\\d+)?)',
    caseSensitive: false,
  ).allMatches(text);
  double? value;
  for (final match in matches) {
    final parsed = double.tryParse(match.group(1) ?? '');
    if (parsed != null && parsed.isFinite) {
      value = parsed;
    }
  }
  return value;
}

double? estimateBroadbandSpectralCutoffHz({
  required Uint8List rgba,
  required int width,
  required int height,
  required double maxFrequencyHz,
}) {
  if (width <= 0 ||
      height <= 0 ||
      maxFrequencyHz <= 0 ||
      rgba.length < width * height * 4) {
    return null;
  }

  // A high percentile captures musical energy without letting a handful of
  // transient pixels dictate the cutoff. Work in an integer histogram so the
  // calculation stays deterministic and cheap enough for a background isolate.
  final rowStrength = Float64List(height);
  final histogram = Uint32List(256);
  final percentileTarget = math.max(0, (width * 0.90).floor());
  for (var y = 0; y < height; y++) {
    histogram.fillRange(0, histogram.length, 0);
    final rowStart = y * width * 4;
    for (var x = 0; x < width; x++) {
      final offset = rowStart + x * 4;
      final intensity = math.max(
        rgba[offset],
        math.max(rgba[offset + 1], rgba[offset + 2]),
      );
      histogram[intensity]++;
    }

    var cumulative = 0;
    for (var value = 0; value < histogram.length; value++) {
      cumulative += histogram[value];
      if (cumulative > percentileTarget) {
        rowStrength[y] = value / 255.0;
        break;
      }
    }
  }

  final hzPerRow = maxFrequencyHz / height;
  final smoothingRadius = math.max(1, (375 / hzPerRow).ceil());
  final smoothed = Float64List(height);
  var maximum = 0.0;
  var running = 0.0;
  var windowStart = 0;
  var windowEnd = -1;
  for (var y = 0; y < height; y++) {
    final desiredStart = math.max(0, y - smoothingRadius);
    final desiredEnd = math.min(height - 1, y + smoothingRadius);
    while (windowEnd < desiredEnd) {
      windowEnd++;
      running += rowStrength[windowEnd];
    }
    while (windowStart < desiredStart) {
      running -= rowStrength[windowStart];
      windowStart++;
    }
    final value = running / (windowEnd - windowStart + 1);
    smoothed[y] = value;
    if (value > maximum) maximum = value;
  }
  if (maximum <= 0) return null;

  // Absolute floor rejects the deep-blue -100 dBFS noise floor. The relative
  // term adapts to quiet masters. A valid edge must span at least 1.5 kHz,
  // which deliberately rejects isolated ultrasonic pilot tones.
  final activeThreshold = math.max(0.035, maximum * 0.10);
  final minimumBandRows = math.max(3, (1500 / hzPerRow).ceil());
  var runStart = -1;
  var runLength = 0;
  for (var y = 0; y < height; y++) {
    if (smoothed[y] >= activeThreshold) {
      if (runStart < 0) runStart = y;
      runLength++;
      if (runLength >= minimumBandRows) {
        final frequency = (height - runStart) / height * maxFrequencyHz;
        return frequency.clamp(0.0, maxFrequencyHz).toDouble();
      }
    } else {
      runStart = -1;
      runLength = 0;
    }
  }
  return null;
}

class AudioAnalysisCard extends StatefulWidget {
  final String filePath;

  const AudioAnalysisCard({super.key, required this.filePath});

  @override
  State<AudioAnalysisCard> createState() => _AudioAnalysisCardState();
}

class _AudioAnalysisCardState extends State<AudioAnalysisCard> {
  AudioAnalysisData? _data;
  bool _analyzing = false;
  bool _checkingCache = true;
  String? _error;
  ui.Image? _spectrogramImage;
  int _spectrogramChannel = -1;
  bool _spectrogramChannelLoading = false;
  int _spectrogramRequestId = 0;

  static const _supportedExtensions = {
    '.flac',
    '.mp3',
    '.m4a',
    '.mp4',
    '.aac',
    '.ac3',
    '.eac3',
    '.opus',
    '.ogg',
    '.wav',
    '.wma',
    '.mka',
    '.wv',
    '.ape',
    '.tta',
    '.aif',
    '.aiff',
  };

  bool get _isSupported {
    final lower = widget.filePath.toLowerCase();
    return _supportedExtensions.any((ext) => lower.endsWith(ext));
  }

  @override
  void initState() {
    super.initState();
    if (_isSupported) {
      _tryLoadFromCache();
    }
  }

  @override
  void dispose() {
    _spectrogramRequestId++;
    _spectrogramImage?.dispose();
    super.dispose();
  }

  Future<void> _tryLoadFromCache() async {
    try {
      final cached = await _loadFromCache(widget.filePath);
      if (cached != null && mounted) {
        setState(() {
          _data = cached;
          _checkingCache = false;
        });
        var image = await _loadSpectrogramFromCache(
          widget.filePath,
          channel: _spectrogramChannel,
        );
        image ??= await _generateAndCacheSpectrogram();
        if (mounted) {
          setState(() {
            _spectrogramImage?.dispose();
            _spectrogramImage = image;
          });
        } else {
          image.dispose();
        }
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _checkingCache = false);
    }
  }

  Future<ui.Image> _generateAndCacheSpectrogram() async {
    final artifact = await _generateSpectrogramForFile(
      widget.filePath,
      channel: _spectrogramChannel,
    );
    await _saveSpectrogramToCache(
      widget.filePath,
      artifact.image,
      channel: _spectrogramChannel,
    );
    return artifact.image;
  }

  Future<void> _analyze({bool forceRefresh = false}) async {
    if (_analyzing) return;
    setState(() {
      _spectrogramRequestId++;
      _analyzing = true;
      _spectrogramChannelLoading = false;
      _error = null;
      if (forceRefresh) {
        _spectrogramImage?.dispose();
        _spectrogramImage = null;
        _data = null;
        _spectrogramChannel = -1;
      }
    });

    try {
      if (forceRefresh) {
        await _clearCache(widget.filePath);
      }

      final cached = forceRefresh
          ? null
          : await _loadFromCache(widget.filePath);
      AudioAnalysisData data;
      ui.Image? image;

      if (cached != null) {
        data = cached;
        image = await _loadSpectrogramFromCache(
          widget.filePath,
          channel: _spectrogramChannel,
        );
      } else {
        final result = await _runAnalysis(widget.filePath);
        data = result.data;
        image = result.spectrogramImage;
        await _saveToCache(widget.filePath, data);
        await _saveSpectrogramToCache(
          widget.filePath,
          image,
          channel: _spectrogramChannel,
        );
      }

      image ??= await _generateAndCacheSpectrogram();

      if (mounted) {
        setState(() {
          _data = data;
          _spectrogramImage?.dispose();
          _spectrogramImage = image;
          _analyzing = false;
        });
      } else {
        image.dispose();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _analyzing = false;
        });
      }
    }
  }

  static Future<void> _clearCache(String filePath) async {
    try {
      final dir = await _cacheDir();
      final key = _cacheKey(filePath);
      final jsonFile = File('${dir.path}/$key.json');
      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        final isCombined = name == '$key.png';
        final isChannel = name.startsWith('${key}_ch') && name.endsWith('.png');
        if (isCombined || isChannel) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  static String _cacheKey(String filePath) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(filePath)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static Future<Directory> _cacheDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/audio_analysis_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<AudioAnalysisData?> _loadFromCache(String filePath) async {
    try {
      final dir = await _cacheDir();
      final key = _cacheKey(filePath);
      final file = File('${dir.path}/$key.json');
      if (!await file.exists()) return null;

      final json = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (json['cacheVersion'] != AudioAnalysisData.cacheVersion) {
        return null;
      }
      final cachedSize = json['fileSize'] as int;

      if (!filePath.startsWith('content://')) {
        final currentSize = await File(filePath).length();
        if (currentSize != cachedSize) return null;
      } else {
        final stat = await PlatformBridge.safStat(filePath);
        final currentSize = (stat['size'] as num?)?.toInt() ?? 0;
        if (currentSize > 0 && currentSize != cachedSize) return null;
      }

      return AudioAnalysisData.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveToCache(
    String filePath,
    AudioAnalysisData data,
  ) async {
    try {
      final dir = await _cacheDir();
      final key = _cacheKey(filePath);
      final file = File('${dir.path}/$key.json');
      await file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {}
  }

  static Future<void> _saveSpectrogramToCache(
    String filePath,
    ui.Image image, {
    required int channel,
  }) async {
    try {
      final dir = await _cacheDir();
      final key = _cacheKey(filePath);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final file = File(
          '${dir.path}/${_spectrogramCacheFileName(key, channel)}',
        );
        await file.writeAsBytes(byteData.buffer.asUint8List());
      }
    } catch (_) {}
  }

  static String _spectrogramCacheFileName(String key, int channel) =>
      channel < 0 ? '$key.png' : '${key}_ch$channel.png';

  static Future<ui.Image?> _loadSpectrogramFromCache(
    String filePath, {
    required int channel,
  }) async {
    try {
      final dir = await _cacheDir();
      final key = _cacheKey(filePath);
      final file = File(
        '${dir.path}/${_spectrogramCacheFileName(key, channel)}',
      );
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      return completer.future;
    } catch (_) {
      return null;
    }
  }

  Future<_AudioAnalysisRunResult> _runAnalysis(String filePath) async {
    await FFmpegKitConfig.setLogLevel(Level.avLogError);

    String workingPath = filePath;
    String? tempCopy;
    if (filePath.startsWith('content://')) {
      tempCopy = await PlatformBridge.copyContentUriToTemp(filePath);
      if (tempCopy == null) {
        throw Exception('Failed to copy SAF file for analysis');
      }
      workingPath = tempCopy;
    }

    try {
      final info = await _getMediaInfo(workingPath);
      _GeneratedSpectrogram? spectrogram;
      try {
        spectrogram = await _generateSpectrogram(workingPath, channel: -1);
        final spectralCutoffHz = await compute(
          _estimateBroadbandSpectralCutoffInIsolate,
          _SpectralCutoffParams(
            rgba: spectrogram.rgba,
            width: audioSpectrogramWidth,
            height: audioSpectrogramHeight,
            maxFrequencyHz: info.sampleRate / 2,
          ),
        );
        final levelMetrics = await _runFullStreamLevelAnalysis(workingPath);
        if (levelMetrics == null) {
          throw Exception('FFmpeg level analysis returned no usable metrics');
        }
        final loudnessMetrics = await _runLoudnessAnalysis(workingPath);
        final peakAmplitude = levelMetrics.peakDb;
        final rmsLevel = levelMetrics.rmsDb;
        final dynamicRange = peakAmplitude - rmsLevel;

        return _AudioAnalysisRunResult(
          data: AudioAnalysisData(
            filePath: filePath,
            fileSize: info.fileSize,
            codec: info.codec,
            container: info.container,
            decodedSampleFormat: info.decodedSampleFormat,
            sampleRate: info.sampleRate,
            channels: info.channels,
            channelLayout: info.channelLayout,
            bitsPerSample: info.bitsPerSample,
            duration: info.duration,
            bitrate: info.bitrate,
            bitDepth: info.bitsPerSample > 0
                ? '${info.bitsPerSample}-bit'
                : 'N/A',
            dynamicRange: dynamicRange,
            peakAmplitude: peakAmplitude,
            rmsLevel: rmsLevel,
            integratedLufs: loudnessMetrics?.integratedLufs,
            truePeakDb: loudnessMetrics?.truePeakDb,
            clippingSamples: levelMetrics.clippingSamples,
            spectralCutoffHz: spectralCutoffHz,
            channelStats: levelMetrics.channelStats,
            totalSamples: info.totalSamples,
          ),
          spectrogramImage: spectrogram.image,
        );
      } catch (_) {
        spectrogram?.image.dispose();
        rethrow;
      }
    } finally {
      if (tempCopy != null) {
        try {
          await File(tempCopy).delete();
        } catch (_) {}
      }
      await FFmpegKitConfig.setLogLevel(Level.avLogInfo);
    }
  }

  Future<_GeneratedSpectrogram> _generateSpectrogramForFile(
    String filePath, {
    required int channel,
  }) async {
    String workingPath = filePath;
    String? tempCopy;
    if (filePath.startsWith('content://')) {
      tempCopy = await PlatformBridge.copyContentUriToTemp(filePath);
      if (tempCopy == null) {
        throw Exception('Failed to copy SAF file for spectrogram');
      }
      workingPath = tempCopy;
    }

    try {
      return await _generateSpectrogram(workingPath, channel: channel);
    } finally {
      if (tempCopy != null) {
        try {
          await File(tempCopy).delete();
        } catch (_) {}
      }
    }
  }

  Future<_GeneratedSpectrogram> _generateSpectrogram(
    String inputPath, {
    required int channel,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final rawPath =
        '${tempDir.path}/analysis_spectrum_'
        '${DateTime.now().microsecondsSinceEpoch}_${channel + 1}.rgba';

    try {
      final session = await FFmpegKit.executeWithArguments(
        buildAudioSpectrogramArguments(
          inputPath: inputPath,
          outputPath: rawPath,
          channel: channel,
        ),
      );

      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getLogsAsString();
        throw Exception('FFmpeg spectrogram failed: $logs');
      }

      final expectedLength = audioSpectrogramWidth * audioSpectrogramHeight * 4;
      final rawBytes = await File(rawPath).readAsBytes();
      if (rawBytes.length < expectedLength) {
        throw Exception(
          'Incomplete spectrogram output '
          '(${rawBytes.length}/$expectedLength bytes)',
        );
      }
      final rgba = rawBytes.length == expectedLength
          ? rawBytes
          : Uint8List.sublistView(rawBytes, 0, expectedLength);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        audioSpectrogramWidth,
        audioSpectrogramHeight,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return _GeneratedSpectrogram(image: await completer.future, rgba: rgba);
    } finally {
      try {
        await File(rawPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _changeSpectrogramChannel(int channel) async {
    final data = _data;
    if (data == null ||
        channel == _spectrogramChannel ||
        channel < -1 ||
        channel >= data.channels) {
      return;
    }

    final previousChannel = _spectrogramChannel;
    final requestId = ++_spectrogramRequestId;
    setState(() {
      _spectrogramChannel = channel;
      _spectrogramChannelLoading = true;
    });

    ui.Image? image;
    try {
      image = await _loadSpectrogramFromCache(
        widget.filePath,
        channel: channel,
      );
      if (image == null) {
        final artifact = await _generateSpectrogramForFile(
          widget.filePath,
          channel: channel,
        );
        image = artifact.image;
        await _saveSpectrogramToCache(widget.filePath, image, channel: channel);
      }

      if (!mounted || requestId != _spectrogramRequestId) {
        image.dispose();
        return;
      }
      setState(() {
        _spectrogramImage?.dispose();
        _spectrogramImage = image;
        _spectrogramChannelLoading = false;
      });
    } catch (_) {
      image?.dispose();
      if (mounted && requestId == _spectrogramRequestId) {
        setState(() {
          _spectrogramChannel = previousChannel;
          _spectrogramChannelLoading = false;
        });
      }
    }
  }

  Future<_MediaInfo> _getMediaInfo(String filePath) async {
    final session = await FFprobeKit.getMediaInformation(filePath);
    final info = session.getMediaInformation();

    if (info == null) {
      throw Exception('Failed to get media information');
    }

    int fileSize = 0;
    try {
      fileSize = await File(filePath).length();
    } catch (_) {}

    final streams = info.getStreams();
    final audioStream = streams.firstWhere(
      (s) => s.getAllProperties()?['codec_type'] == 'audio',
      orElse: () => throw Exception('No audio stream found'),
    );

    final props = audioStream.getAllProperties() ?? {};
    final infoProps = info.getAllProperties() ?? {};
    final codecName = props['codec_name']?.toString().toLowerCase() ?? '';
    final codecLongName = props['codec_long_name']?.toString() ?? '';
    final decodedSampleFormat = props['sample_fmt']?.toString() ?? '';
    final formatName = infoProps['format_name']?.toString() ?? '';
    final formatLongName = infoProps['format_long_name']?.toString() ?? '';
    final sampleRate =
        int.tryParse(props['sample_rate']?.toString() ?? '') ?? 0;
    final channels = int.tryParse(props['channels']?.toString() ?? '') ?? 0;
    final channelLayout =
        props['channel_layout']?.toString() ??
        props['ch_layout']?.toString() ??
        '';
    final streamDuration = double.tryParse(props['duration']?.toString() ?? '');
    final containerDuration = double.tryParse(info.getDuration() ?? '');
    final duration =
        (streamDuration != null && streamDuration > 0
            ? streamDuration
            : containerDuration) ??
        0;
    final streamBitrate = int.tryParse(props['bit_rate']?.toString() ?? '');
    final containerBitrate = int.tryParse(info.getBitrate() ?? '');
    final bitrate =
        streamBitrate ??
        containerBitrate ??
        (duration > 0 && fileSize > 0 ? (fileSize * 8 / duration).round() : 0);

    final canReportStoredBitDepth = _codecHasStoredBitDepth(codecName);

    int bitsPerSample = 0;
    if (canReportStoredBitDepth) {
      bitsPerSample =
          int.tryParse(props['bits_per_raw_sample']?.toString() ?? '') ?? 0;
      if (bitsPerSample == 0) {
        bitsPerSample =
            int.tryParse(props['bits_per_sample']?.toString() ?? '') ?? 0;
      }
    }

    if (bitsPerSample == 0 && canReportStoredBitDepth) {
      final sampleFmt = props['sample_fmt']?.toString() ?? '';
      if (sampleFmt.contains('16') ||
          sampleFmt == 's16' ||
          sampleFmt == 's16p') {
        bitsPerSample = 16;
      } else if (sampleFmt.contains('32') ||
          sampleFmt == 'flt' ||
          sampleFmt == 'fltp') {
        bitsPerSample = 32;
      } else if (sampleFmt.contains('24') || sampleFmt == 's24') {
        bitsPerSample = 24;
      }
    }

    return _MediaInfo(
      fileSize: fileSize,
      codec: _formatCodecLabel(codecName, codecLongName),
      container: _formatContainerLabel(formatName, formatLongName),
      decodedSampleFormat: decodedSampleFormat,
      sampleRate: sampleRate,
      channels: channels,
      channelLayout: channelLayout,
      bitsPerSample: bitsPerSample,
      duration: duration,
      bitrate: bitrate,
      totalSamples: _estimateTotalSamples(
        props: props,
        duration: duration,
        sampleRate: sampleRate,
        channels: channels,
      ),
    );
  }

  String _formatCodecLabel(String codecName, String codecLongName) {
    final name = codecName.trim();
    final longName = _normalizeAnalysisLabel(codecLongName);
    if (name.isEmpty) return longName;
    if (longName.isEmpty || longName.toLowerCase() == name.toLowerCase()) {
      return name.toUpperCase();
    }
    return '${name.toUpperCase()} ($longName)';
  }

  String _formatContainerLabel(String formatName, String formatLongName) {
    final longName = _normalizeAnalysisLabel(formatLongName);
    if (longName.isNotEmpty) return longName;
    final name = formatName.trim();
    return name.isEmpty ? '' : name.toUpperCase();
  }

  String _normalizeAnalysisLabel(String value) {
    final trimmed = value.trim();
    final lower = trimmed.toLowerCase();
    if (lower.isEmpty || lower == 'unknown' || lower == 'n/a') return '';
    return trimmed;
  }

  int _estimateTotalSamples({
    required Map<dynamic, dynamic> props,
    required double duration,
    required int sampleRate,
    required int channels,
  }) {
    final nbSamples = int.tryParse(props['nb_samples']?.toString() ?? '');
    if (nbSamples != null && nbSamples > 0) {
      return nbSamples;
    }

    final durationTs = int.tryParse(props['duration_ts']?.toString() ?? '');
    final timeBase = props['time_base']?.toString() ?? '';
    if (durationTs != null && durationTs > 0 && timeBase.contains('/')) {
      final parts = timeBase.split('/');
      final numerator = double.tryParse(parts[0]);
      final denominator = double.tryParse(parts[1]);
      if (numerator != null &&
          numerator > 0 &&
          denominator != null &&
          denominator > 0 &&
          sampleRate > 0) {
        final seconds = durationTs * numerator / denominator;
        return (seconds * sampleRate).round();
      }
    }

    if (duration > 0 && sampleRate > 0) {
      return (duration * sampleRate).round();
    }
    return 0;
  }

  bool _codecHasStoredBitDepth(String codecName) {
    if (codecName.isEmpty) return false;
    return codecName == 'flac' ||
        codecName == 'alac' ||
        codecName == 'wavpack' ||
        codecName == 'ape' ||
        codecName == 'tta' ||
        codecName.startsWith('pcm_');
  }

  Future<_LevelMetrics?> _runFullStreamLevelAnalysis(String inputPath) async {
    await FFmpegKitConfig.setLogLevel(Level.avLogInfo);
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-v',
        'info',
        '-hide_banner',
        '-nostats',
        '-i',
        inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-sn',
        '-dn',
        '-af',
        'astats=metadata=1:reset=0',
        '-f',
        'null',
        '-',
      ]);

      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        return null;
      }

      // FFmpegKit delivers logs asynchronously even after the process exits.
      // The non-waiting getLogsAsString() can miss the final astats summary.
      final logs = await session.getAllLogsAsString() ?? '';
      final summary = parseAudioAstatsSummary(logs);
      if (summary == null) return null;
      final channelStats = _parseChannelStats(logs);
      final clippingSamples = channelStats.fold<int>(0, (sum, stats) {
        if (stats.peakDb == null || stats.peakDb! < -0.1) return sum;
        return sum + stats.peakCount;
      });
      return _LevelMetrics(
        peakDb: summary.peakDb,
        rmsDb: summary.rmsDb,
        clippingSamples: clippingSamples,
        channelStats: channelStats,
      );
    } finally {
      await FFmpegKitConfig.setLogLevel(Level.avLogError);
    }
  }

  Future<_LoudnessMetrics?> _runLoudnessAnalysis(String inputPath) async {
    await FFmpegKitConfig.setLogLevel(Level.avLogInfo);
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-hide_banner',
        '-nostats',
        '-i',
        inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-sn',
        '-dn',
        '-af',
        'ebur128=peak=true:framelog=quiet',
        '-f',
        'null',
        '-',
      ]);

      final logs = await session.getAllLogsAsString() ?? '';
      final integratedMatches = RegExp(
        r'I:\s+(-?\d+\.?\d*)\s+LUFS',
      ).allMatches(logs);
      final integrated = integratedMatches.isEmpty
          ? null
          : double.tryParse(integratedMatches.last.group(1) ?? '');

      double? truePeak;
      for (final match in RegExp(
        r'Peak:\s+(-?\d+\.?\d*)\s+dBFS',
      ).allMatches(logs)) {
        final value = double.tryParse(match.group(1) ?? '');
        if (value != null && (truePeak == null || value > truePeak)) {
          truePeak = value;
        }
      }

      if (integrated == null && truePeak == null) return null;
      return _LoudnessMetrics(integratedLufs: integrated, truePeakDb: truePeak);
    } finally {
      await FFmpegKitConfig.setLogLevel(Level.avLogError);
    }
  }

  List<ChannelAnalysisStats> _parseChannelStats(String logs) {
    final stats = <ChannelAnalysisStats>[];
    final channelMatches = RegExp(
      r'Channel:\s*(\d+)([\s\S]*?)(?=Channel:\s*\d+|Overall|$)',
      caseSensitive: false,
    ).allMatches(logs);

    for (final match in channelMatches) {
      final channel = int.tryParse(match.group(1) ?? '') ?? 0;
      final section = match.group(2) ?? '';
      if (channel <= 0 || section.trim().isEmpty) continue;
      final peakDb = _parseLastAstatsValue(section, 'Peak level dB');
      final rmsDb = _parseLastAstatsValue(section, 'RMS level dB');
      stats.add(
        ChannelAnalysisStats(
          channel: channel,
          peakDb: peakDb,
          rmsDb: rmsDb,
          dynamicRangeDb: peakDb != null && rmsDb != null
              ? peakDb - rmsDb
              : null,
          peakCount:
              _parseLastAstatsInt(section, 'Peak count') ??
              _parseLastAstatsInt(section, 'Peak count ch') ??
              0,
        ),
      );
    }

    return stats;
  }

  double? _parseLastAstatsValue(String text, String label) {
    return _parseLastAudioAstatsValue(text, label);
  }

  int? _parseLastAstatsInt(String text, String label) {
    final matches = RegExp(
      '${RegExp.escape(label)}:\\s*(\\d+)',
      caseSensitive: false,
    ).allMatches(text);
    int? value;
    for (final match in matches) {
      value = int.tryParse(match.group(1) ?? '') ?? value;
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSupported) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    if (_checkingCache) return const SizedBox.shrink();

    if (_analyzing) {
      final isRescan = _data != null || _spectrogramImage != null;
      return Card(
        elevation: 0,
        color: settingsGroupColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: 12),
                Text(
                  isRescan
                      ? l10n.audioAnalysisRescanning
                      : l10n.audioAnalysisAnalyzing,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Card(
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: cs.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: l10n.audioAnalysisRescan,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                color: cs.onErrorContainer,
                onPressed: () => _analyze(forceRefresh: true),
              ),
            ],
          ),
        ),
      );
    }

    if (_data == null) {
      return Card(
        elevation: 0,
        color: settingsGroupColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          onTap: _analyze,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(Icons.analytics_outlined, color: cs.primary, size: 28),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.audioAnalysisTitle,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.audioAnalysisDescription,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    final data = _data!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AudioInfoCard(
          data: data,
          onRescan: () => _analyze(forceRefresh: true),
        ),
        if (_spectrogramImage != null) ...[
          const SizedBox(height: 12),
          _SpectrogramView(
            image: _spectrogramImage!,
            sampleRate: data.sampleRate,
            maxFreq: data.sampleRate / 2,
            duration: data.duration,
            channels: data.channels,
            selectedChannel: _spectrogramChannel,
            channelLoading: _spectrogramChannelLoading,
            onChannelChanged: _changeSpectrogramChannel,
          ),
        ],
      ],
    );
  }
}
