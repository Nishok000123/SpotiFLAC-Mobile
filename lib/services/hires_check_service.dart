import 'package:spotiflac_android/services/platform_bridge.dart';

/// Outcome of the Go fake Hi-Res check (go_backend/hires_check.go).
class HiResCheckResult {
  final bool supported;
  final String verdict;
  final int declaredSampleRate;
  final double cutoffFrequencyHz;
  final int declaredBitDepth;
  final int effectiveBitDepth;
  final bool paddedBitDepth;
  final String reason;

  /// For a fake: 'certain', 'likely' or 'suspect' (may be a genuine master
  /// low-pass filtered in mastering). Empty otherwise.
  final String confidence;

  /// 'sample_hold', 'linear_interpolation', 'imaging', or empty.
  final String upsamplingArtifact;

  /// True only when a LOSSLESS copy would lose nothing this file holds.
  final bool redownloadSafe;

  /// Highest frequency whose level still moves with the music; 0 when not
  /// measured.
  final double musicCutoffHz;

  /// True when the content past [musicCutoffHz] is steady noise (a DSD or
  /// analog tape transfer), so [cutoffFrequencyHz] is where noise ends.
  final bool ultrasonicNoiseOnly;

  /// With [ultrasonicNoiseOnly]: the lowest standard rate that holds all
  /// the music. Otherwise the declared rate.
  final int usefulSampleRate;

  const HiResCheckResult({
    required this.supported,
    this.verdict = '',
    this.declaredSampleRate = 0,
    this.cutoffFrequencyHz = 0,
    this.declaredBitDepth = 0,
    this.effectiveBitDepth = 0,
    this.paddedBitDepth = false,
    this.reason = '',
    this.confidence = '',
    this.upsamplingArtifact = '',
    this.redownloadSafe = false,
    this.musicCutoffHz = 0,
    this.ultrasonicNoiseOnly = false,
    this.usefulSampleRate = 0,
  });

  factory HiResCheckResult.fromJson(Map<String, dynamic> json) {
    return HiResCheckResult(
      supported: json['supported'] == true,
      verdict: json['verdict'] as String? ?? '',
      declaredSampleRate: (json['declared_sample_rate'] as num?)?.toInt() ?? 0,
      cutoffFrequencyHz: (json['cutoff_frequency_hz'] as num?)?.toDouble() ?? 0,
      declaredBitDepth: (json['declared_bit_depth'] as num?)?.toInt() ?? 0,
      effectiveBitDepth: (json['effective_bit_depth'] as num?)?.toInt() ?? 0,
      paddedBitDepth: json['padded_bit_depth'] == true,
      reason: json['reason'] as String? ?? '',
      confidence: json['confidence'] as String? ?? '',
      upsamplingArtifact: json['upsampling_artifact'] as String? ?? '',
      redownloadSafe: json['redownload_safe'] == true,
      musicCutoffHz: (json['music_cutoff_hz'] as num?)?.toDouble() ?? 0,
      ultrasonicNoiseOnly: json['ultrasonic_noise_only'] == true,
      usefulSampleRate: (json['useful_sample_rate'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isFake => verdict == 'fake_hires';

  bool get isCertain => isFake && confidence == 'certain';
  bool get isSuspect => isFake && confidence == 'suspect';

  /// Mirrors the Go thresholds: a rate claim above 48 kHz whose content
  /// stops below 28 kHz. Recomputed here so the reason can be localized.
  bool get upsampled =>
      isFake && declaredSampleRate > 48000 && cutoffFrequencyHz < 28000;
}

class HiResCheckService {
  /// The requested qualities that actually claim Hi-Res. A LOSSLESS request
  /// answered with CD-range audio is not a fake: it is what was asked for.
  static const hiResQualities = {'HI_RES', 'HI_RES_LOSSLESS'};

  /// What a flagged download is replaced with. An upsampled 24/96 file holds
  /// no more information than the CD master it was made from, so this is the
  /// same audio, honestly labelled and smaller.
  static const fakeHiResFallbackQuality = 'LOSSLESS';

  /// Suffix of the flagged file while its replacement downloads. It is only
  /// deleted once the replacement exists: a heuristic is not a good enough
  /// reason to leave the user with no copy of the track at all.
  static const quarantineSuffix = '.fake-hires.bak';

  static bool isHiResQuality(String quality) =>
      hiResQualities.contains(quality.trim().toUpperCase());

  /// Runs the check; throws on failure. `supported == false` for formats
  /// the Go checker cannot decode (anything but FLAC and PCM WAV).
  static Future<HiResCheckResult> check(String filePath) async {
    final json = await PlatformBridge.checkHiResAuthenticity(filePath);
    final error = json['error'];
    if (error != null) throw StateError(error.toString());
    return HiResCheckResult.fromJson(json);
  }
}
