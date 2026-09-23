part of 'download_queue_provider.dart';

// Per-track fake Hi-Res check (AppSettings.redownloadFakeHiRes), ported from
// SpotiFLAC-Module-Version's --redownload-fake-hires.
//
// Runs inside one _DownloadRun, right after the file is decoded and before
// anything is published, tagged or converted: the verdict decides which file
// the rest of the pipeline works on. A flagged file is set aside, the same
// track is downloaded again at LOSSLESS, and only then is the flagged file
// deleted. If the replacement fails the original is put back unchanged.

enum _FakeHiResOutcome {
  /// Nothing to do, or the replacement failed: finish with the current file.
  kept,

  /// `result` now holds the LOSSLESS replacement; finalize that instead.
  replaced,

  /// The item was cancelled or paused mid-replacement; stop the run.
  aborted,
}

/// Everything a replacement attempt may overwrite, so a failed one can put
/// the run back exactly as it was.
class _FakeHiResRunState {
  _FakeHiResRunState(_DownloadRun run)
    : result = run.result,
      quality = run.quality,
      safOutputExt = run.safOutputExt,
      safFileName = run.safFileName,
      safBaseName = run.safBaseName,
      finalSafFileName = run.finalSafFileName,
      effectiveSafMode = run.effectiveSafMode,
      effectiveOutputDir = run.effectiveOutputDir,
      trackToDownload = run.trackToDownload;

  final Map<String, dynamic> result;
  final String quality;
  final String safOutputExt;
  final String? safFileName;
  final String? safBaseName;
  final String? finalSafFileName;
  final bool effectiveSafMode;
  final String effectiveOutputDir;
  final Track trackToDownload;

  void restore(_DownloadRun run) {
    run.result = result;
    run.quality = quality;
    run.safOutputExt = safOutputExt;
    run.safFileName = safFileName;
    run.safBaseName = safBaseName;
    run.finalSafFileName = finalSafFileName;
    run.effectiveSafMode = effectiveSafMode;
    run.effectiveOutputDir = effectiveOutputDir;
    run.trackToDownload = trackToDownload;
  }
}

extension _DownloadRunFakeHiRes on _DownloadRun {
  /// [requestTrack] is the track as it was sent to the backend, before the
  /// first result was merged into it: the replacement gets the same brief
  /// the first attempt did, not the first attempt's conclusions.
  Future<_FakeHiResOutcome> _replaceFakeHiResIfNeeded(
    Track requestTrack,
  ) async {
    final path = filePath;
    if (!settings.redownloadFakeHiRes ||
        wasExisting ||
        path == null ||
        !HiResCheckService.isHiResQuality(quality)) {
      return _FakeHiResOutcome.kept;
    }
    if (isContentUri(path)) {
      // Already published to SAF: there is no local file to set aside, and
      // a heuristic is not worth deleting the only copy for.
      _log.d('[hires-check] skipped: output already published to SAF');
      return _FakeHiResOutcome.kept;
    }
    if (!_serviceOffersFakeHiResFallback()) {
      _log.d(
        '[hires-check] skipped: ${item.service} has no '
        '${HiResCheckService.fakeHiResFallbackQuality} quality',
      );
      return _FakeHiResOutcome.kept;
    }

    final HiResCheckResult check;
    try {
      check = await HiResCheckService.check(path);
    } catch (e) {
      // Never a reason to fail a finished download.
      _log.w('[hires-check] skipped for ${item.track.name}: $e');
      return _FakeHiResOutcome.kept;
    }
    if (!check.supported || !check.isFake) {
      _log.d(
        '[hires-check] ${item.track.name}: '
        '${check.supported ? check.verdict : 'unsupported format'}',
      );
      return _FakeHiResOutcome.kept;
    }
    if (!check.redownloadSafe) {
      // A suspect may be a genuine master low-pass filtered in mastering;
      // a LOSSLESS copy could lose bit depth it really has. Report only.
      _log.w(
        '[hires-check] ${item.track.name} may be fake Hi-Res '
        '(${check.reason}); kept, not certain enough to replace',
      );
      return _FakeHiResOutcome.kept;
    }

    _log.w(
      '[hires-check] ${item.track.name} looks like fake Hi-Res '
      '(${check.reason}); re-downloading as '
      '${HiResCheckService.fakeHiResFallbackQuality}',
    );

    final quarantined = '$path${HiResCheckService.quarantineSuffix}';
    try {
      await File(path).rename(quarantined);
    } catch (e) {
      _log.w('[hires-check] could not set aside $path, keeping it: $e');
      return _FakeHiResOutcome.kept;
    }

    final saved = _FakeHiResRunState(this);
    var keepQuarantine = false;
    try {
      trackToDownload = requestTrack;
      await _useFakeHiResFallbackQuality();
      n.updateItemStatus(item.id, DownloadStatus.downloading, progress: 0);

      if (!await _downloadAndMaybeFallback()) {
        await deleteFile(quarantined);
        return _FakeHiResOutcome.aborted;
      }
      final replacementPath = result['file_path'] as String?;
      if (await _shouldAbort(
        'during fake Hi-Res re-download',
        deleteFileOnAbort: result['success'] == true ? replacementPath : null,
      )) {
        await deleteFile(quarantined);
        return _FakeHiResOutcome.aborted;
      }

      final replaced =
          result['success'] == true &&
          result['already_exists'] != true &&
          normalizeOptionalString(replacementPath) != null;
      if (!replaced) {
        _log.w(
          '[hires-check] ${HiResCheckService.fakeHiResFallbackQuality} '
          're-download of ${item.track.name} failed '
          '(${result['error'] ?? 'no file'}); keeping the flagged file',
        );
        keepQuarantine = true;
        return _FakeHiResOutcome.kept;
      }

      await deleteFile(quarantined);
      // Mirrors _run: the SAF folder is resolved per result.
      if (effectiveSafMode && result['saf_relative_dir'] is String) {
        effectiveOutputDir = n._sanitizeSafRelativeDir(
          result['saf_relative_dir'] as String,
        );
      }
      _log.i(
        '[hires-check] replaced fake Hi-Res ${item.track.name} with '
        '$replacementPath',
      );
      return _FakeHiResOutcome.replaced;
    } catch (e) {
      _log.w('[hires-check] re-download of ${item.track.name} failed: $e');
      keepQuarantine = true;
      return _FakeHiResOutcome.kept;
    } finally {
      if (keepQuarantine) {
        saved.restore(this);
        try {
          await File(quarantined).rename(path);
        } catch (e) {
          _log.e('[hires-check] could not restore $path from $quarantined: $e');
        }
      }
    }
  }

  /// Only LOSSLESS is a meaningful replacement. A provider that does not
  /// list it would silently fall back to its default, which may be the very
  /// Hi-Res tier that produced the fake.
  bool _serviceOffersFakeHiResFallback() {
    final service = item.service.trim().toLowerCase();
    final extension = extensionState.extensions
        .where((e) => e.id.toLowerCase() == service)
        .firstOrNull;
    final options = extension?.qualityOptions ?? const <QualityOption>[];
    return options.isEmpty ||
        options.any(
          (o) =>
              o.id.toUpperCase() == HiResCheckService.fakeHiResFallbackQuality,
        );
  }

  /// Points the next backend request at LOSSLESS. The output folder stays
  /// as resolved (including any storage fallback); only what depends on the
  /// quality is rebuilt.
  Future<void> _useFakeHiResFallbackQuality() async {
    quality = HiResCheckService.fakeHiResFallbackQuality;
    safOutputExt = n._determineOutputExt(quality, item.service);
    if (effectiveSafMode) {
      final name = await n._buildSafFileNameForItem(
        item,
        trackToDownload,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
      safFileName = name;
      safBaseName = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      finalSafFileName = name;
    }
  }
}
