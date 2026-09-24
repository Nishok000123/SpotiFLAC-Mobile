import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/services/hires_check_service.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// On-demand fake Hi-Res check for one FLAC/WAV file: spectral cutoff for
/// upsampling, and unused low bits for a 16-bit master padded to 24.
class HiResCheckCard extends StatefulWidget {
  final String filePath;
  final String? formatHint;

  const HiResCheckCard({super.key, required this.filePath, this.formatHint});

  /// Only FLAC and PCM WAV are decoded by the Go checker.
  static bool isCandidate(String filePath, String? formatHint) {
    final format = formatHint?.toLowerCase().trim() ?? '';
    if (format == 'flac' || format == 'wav') return true;
    final lower = filePath.toLowerCase();
    return lower.endsWith('.flac') || lower.endsWith('.wav');
  }

  @override
  State<HiResCheckCard> createState() => _HiResCheckCardState();
}

class _HiResCheckCardState extends State<HiResCheckCard> {
  HiResCheckResult? _result;
  bool _checking = false;
  String? _error;
  int _requestId = 0;

  @override
  void didUpdateWidget(covariant HiResCheckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _requestId++;
      _result = null;
      _error = null;
      _checking = false;
    }
  }

  Future<void> _check() async {
    final requestId = ++_requestId;
    setState(() {
      _checking = true;
      _error = null;
    });
    String? error;
    HiResCheckResult? result;
    try {
      result = await HiResCheckService.check(widget.filePath);
    } on StateError catch (e) {
      error = e.message;
    } catch (e) {
      error = e.toString();
    }
    if (!mounted || requestId != _requestId) return;
    setState(() {
      _checking = false;
      _result = result;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!HiResCheckCard.isCandidate(widget.filePath, widget.formatHint)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final result = _result;

    return Card(
      elevation: 0,
      color: settingsGroupColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_outlined, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.hiResCheckTitle,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (_checking)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else if (result != null || _error != null)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: l10n.audioAnalysisRescan,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    color: cs.onSurfaceVariant,
                    onPressed: _check,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_checking)
              _secondaryText(l10n.hiResCheckChecking, cs)
            else if (_error != null)
              Text(
                l10n.hiResCheckFailed(_error!),
                style: TextStyle(color: cs.error, fontSize: 13),
              )
            else if (result == null) ...[
              _secondaryText(l10n.hiResCheckDescription, cs),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _check,
                icon: const Icon(Icons.search, size: 18),
                label: Text(l10n.hiResCheckRun),
              ),
            ] else if (!result.supported)
              _secondaryText(l10n.hiResCheckUnsupported, cs)
            else
              ..._buildResult(context, result, cs),
          ],
        ),
      ),
    );
  }

  Widget _secondaryText(String text, ColorScheme cs) {
    return Text(
      text,
      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
    );
  }

  List<Widget> _buildResult(
    BuildContext context,
    HiResCheckResult result,
    ColorScheme cs,
  ) {
    final l10n = context.l10n;
    final (IconData icon, Color color, String label) = switch (result.verdict) {
      'fake_hires' when result.isCertain => (
        Icons.error_outline,
        cs.error,
        l10n.hiResCheckVerdictFakeCertain,
      ),
      'fake_hires' when result.isSuspect => (
        Icons.help_outline,
        cs.tertiary,
        l10n.hiResCheckVerdictFakeSuspect,
      ),
      'fake_hires' => (
        Icons.warning_amber_rounded,
        cs.error,
        l10n.hiResCheckVerdictFake,
      ),
      'genuine_hires' => (
        Icons.check_circle_outline,
        cs.primary,
        l10n.hiResCheckVerdictGenuine,
      ),
      'standard_definition' => (
        Icons.info_outline,
        cs.onSurfaceVariant,
        l10n.hiResCheckVerdictStandard,
      ),
      _ => (
        Icons.help_outline,
        cs.onSurfaceVariant,
        l10n.hiResCheckVerdictInconclusive,
      ),
    };

    final effectiveBits = result.effectiveBitDepth > 0
        ? result.effectiveBitDepth
        : null;
    final reasons = <String>[
      if (result.upsamplingArtifact == 'sample_hold')
        l10n.hiResCheckReasonSampleHold,
      if (result.upsamplingArtifact == 'linear_interpolation')
        l10n.hiResCheckReasonInterpolation,
      if (result.upsamplingArtifact == 'imaging') l10n.hiResCheckReasonImaging,
      if (result.upsampled)
        l10n.hiResCheckReasonRate(
          _formatKHz(result.declaredSampleRate.toDouble()),
          _formatKHz(result.cutoffFrequencyHz),
        ),
      if (result.isFake && result.paddedBitDepth)
        l10n.hiResCheckReasonDepth(
          result.declaredBitDepth,
          result.effectiveBitDepth,
        ),
    ];

    return [
      Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
      for (final reason in reasons) ...[
        const SizedBox(height: 4),
        _secondaryText('• $reason', cs),
      ],
      if (result.ultrasonicNoiseOnly) ...[
        const SizedBox(height: 4),
        _secondaryText(
          '• ${l10n.hiResCheckUltrasonicNoise(_formatKHz(result.musicCutoffHz), _formatKHz(result.usefulSampleRate.toDouble()))}',
          cs,
        ),
      ],
      if (result.verdict != 'inconclusive') ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            // Past the music only steady noise remains, so where it ends
            // says nothing about the music: show the music's own edge.
            if (result.ultrasonicNoiseOnly)
              _detail(
                l10n.hiResCheckMusicContent,
                '~${_formatKHz(result.musicCutoffHz)}',
                cs,
              )
            else
              _detail(
                l10n.hiResCheckCutoff,
                '~${_formatKHz(result.cutoffFrequencyHz)}',
                cs,
              ),
            if (result.declaredBitDepth > 0)
              _detail(
                l10n.hiResCheckBitsInUse,
                '${effectiveBits ?? '?'} / ${result.declaredBitDepth}-bit',
                cs,
              ),
          ],
        ),
      ],
      if (result.isSuspect) ...[
        const SizedBox(height: 8),
        Text(
          l10n.hiResCheckDisclaimer,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    ];
  }

  Widget _detail(String label, String value, ColorScheme cs) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatKHz(double hz) => '${(hz / 1000).toStringAsFixed(1)} kHz';
}
