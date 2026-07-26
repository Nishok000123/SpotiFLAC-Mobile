// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

/// The per-item download pipeline: metadata enrichment, output resolution,
/// the native download call, decrypt/convert/embed finalization, and the
/// history hand-off. Queue scheduling stays in the main file.
extension _SingleItemDownload on DownloadQueueNotifier {
  bool _isSafWriteFailure(Map<String, dynamic> result) {
    final error = (result['error'] ?? result['message'] ?? '')
        .toString()
        .toLowerCase();
    if (error.isEmpty) return false;
    return error.contains('saf') ||
        error.contains('content uri') ||
        error.contains('permission denied') ||
        error.contains('documentfile');
  }

  Future<String?> _runPostProcessingHooks(String filePath, Track track) async {
    try {
      final settings = ref.read(settingsProvider);
      final extensionState = ref.read(extensionProvider);
      final resolvedAlbumArtist = _resolveAlbumArtistForMetadata(
        track,
        settings,
      );

      if (!settings.useExtensionProviders) return null;

      final hasPostProcessing = extensionState.extensions.any(
        (e) => e.enabled && e.hasPostProcessing,
      );
      if (!hasPostProcessing) return null;

      _log.d('Running post-processing hooks on: $filePath');

      final metadata = <String, dynamic>{
        'title': track.name,
        'artist': track.artistName,
        'album': track.albumName,
        'track_number': track.trackNumber ?? 0,
        'disc_number': track.discNumber ?? 0,
        'isrc': track.isrc ?? '',
        'release_date': track.releaseDate ?? '',
        'duration_ms': track.duration * 1000,
        'cover_url': track.coverUrl ?? '',
      };
      if (resolvedAlbumArtist != null) {
        metadata['album_artist'] = resolvedAlbumArtist;
      }

      final result = await PlatformBridge.runPostProcessingV2(
        filePath,
        metadata: metadata,
      );

      if (result['success'] == true) {
        final hooksRun = result['hooks_run'] as int? ?? 0;
        final newPath = result['file_path'] as String?;
        _log.i('Post-processing completed: $hooksRun hook(s) executed');

        if (newPath != null && newPath != filePath) {
          _log.d('File path changed by post-processing: $newPath');
          return newPath;
        }
        return filePath;
      } else {
        final error = result['error'] as String? ?? 'Unknown error';
        _log.w('Post-processing failed: $error');
      }
    } catch (e) {
      _log.w('Post-processing error: $e');
    }
    return null;
  }

  Future<void> _downloadSingleItem(DownloadItem item) async {
    final normalizedService = _normalizeQueuedService(item.service);
    if (normalizedService != item.service) {
      item = item.copyWith(service: normalizedService);
      state = state.copyWith(
        items: [
          for (final existing in state.items)
            if (existing.id == item.id) item else existing,
        ],
        currentDownload: state.currentDownload?.id == item.id
            ? item
            : state.currentDownload,
      );
      _saveQueueToStorage();
    }

    if (!_hasActiveDownloadProvider(item.service)) {
      updateItemStatus(
        item.id,
        DownloadStatus.failed,
        error: 'Download provider is no longer available',
        errorType: DownloadErrorType.notFound,
      );
      return;
    }

    _log.d('Processing: ${item.track.name} by ${item.track.artistName}');
    _log.d('Cover URL: ${item.track.coverUrl}');
    var pausedDuringThisRun = false;

    final currentItem = _findItemById(item.id) ?? item;
    if (_isLocallyCancelled(item.id, item: currentItem)) {
      _log.i('Download was cancelled before start, skipping');
      return;
    }

    if (_isPausePending(item.id)) {
      pausedDuringThisRun = true;
      _requeueItemForPause(item.id);
      _log.i('Download is pause-pending before start, skipping');
      return;
    }

    state = state.copyWith(currentDownload: item);

    updateItemStatus(item.id, DownloadStatus.downloading);

    // Shared guard for every checkpoint below: an item that vanished from the
    // queue or was flagged locally-cancelled aborts immediately; a
    // pause-pending item re-queues instead. [deleteFileOnAbort], when given,
    // is removed before returning (used once a file has already been written).
    Future<bool> shouldAbortWork(
      String stage, {
      String? deleteFileOnAbort,
    }) async {
      final current = _findItemById(item.id);
      if (current == null || _isLocallyCancelled(item.id, item: current)) {
        _log.i('Download was cancelled $stage, skipping');
        if (deleteFileOnAbort != null) {
          await deleteFile(deleteFileOnAbort);
          _log.d('Deleted cancelled download file: $deleteFileOnAbort');
        }
        return true;
      }
      if (_isPausePending(item.id)) {
        pausedDuringThisRun = true;
        if (deleteFileOnAbort != null) {
          await deleteFile(deleteFileOnAbort);
          _log.d('Deleted paused download file: $deleteFileOnAbort');
        }
        _requeueItemForPause(item.id);
        _log.i('Download pause requested $stage, re-queueing');
        return true;
      }
      return false;
    }

    try {
      final settings = ref.read(settingsProvider);
      final metadataEmbeddingEnabled = settings.embedMetadata;

      Track trackToDownload = item.track;
      final needsEnrichment =
          trackToDownload.id.startsWith('deezer:') &&
          (trackToDownload.isrc == null ||
              trackToDownload.isrc!.isEmpty ||
              trackToDownload.trackNumber == null ||
              trackToDownload.trackNumber == 0 ||
              trackToDownload.totalTracks == null ||
              trackToDownload.totalTracks == 0 ||
              (trackToDownload.composer == null ||
                  trackToDownload.composer!.isEmpty));

      if (needsEnrichment) {
        try {
          _log.d(
            'Enriching incomplete metadata for Deezer track: ${trackToDownload.name}',
          );
          _log.d(
            'Current ISRC: ${trackToDownload.isrc}, TrackNumber: ${trackToDownload.trackNumber}',
          );
          final rawId = trackToDownload.id.split(':')[1];
          _log.d('Fetching full metadata for Deezer ID: $rawId');
          final fullData = await PlatformBridge.getProviderMetadata(
            'deezer',
            'track',
            rawId,
          );
          _log.d('Got response keys: ${fullData.keys.toList()}');

          if (fullData.containsKey('track')) {
            final trackData = fullData['track'];
            _log.d('Track data type: ${trackData.runtimeType}');
            if (trackData is Map<String, dynamic>) {
              final data = trackData;
              _log.d('Track data keys: ${data.keys.toList()}');
              _log.d('ISRC from API: ${data['isrc']}');
              _log.d('album_type from API: ${data['album_type']}');
              final enrichedTotalTracks = readPositiveInt(data['total_tracks']);
              final enrichedTotalDiscs = readPositiveInt(data['total_discs']);
              final enrichedComposer = normalizeOptionalString(
                data['composer']?.toString(),
              );
              trackToDownload = Track(
                id: (data['spotify_id'] as String?) ?? trackToDownload.id,
                name: (data['name'] as String?) ?? trackToDownload.name,
                artistName:
                    (data['artists'] as String?) ?? trackToDownload.artistName,
                albumName:
                    (data['album_name'] as String?) ??
                    trackToDownload.albumName,
                albumArtist: data['album_artist'] as String?,
                artistId:
                    (data['artist_id'] ?? data['artistId'])?.toString() ??
                    trackToDownload.artistId,
                albumId:
                    data['album_id']?.toString() ?? trackToDownload.albumId,
                coverUrl: data['images'] as String?,
                duration:
                    ((data['duration_ms'] as int?) ??
                        (trackToDownload.duration * 1000)) ~/
                    1000,
                isrc: (data['isrc'] as String?) ?? trackToDownload.isrc,
                trackNumber: data['track_number'] as int?,
                discNumber: data['disc_number'] as int?,
                totalDiscs: enrichedTotalDiscs ?? trackToDownload.totalDiscs,
                releaseDate: data['release_date'] as String?,
                deezerId: rawId,
                availability: trackToDownload.availability,
                albumType:
                    (data['album_type'] as String?) ??
                    trackToDownload.albumType,
                totalTracks: enrichedTotalTracks ?? trackToDownload.totalTracks,
                composer: enrichedComposer ?? trackToDownload.composer,
                source: trackToDownload.source,
              );
              _log.d(
                'Metadata enriched: Track ${trackToDownload.trackNumber}, Disc ${trackToDownload.discNumber}, ISRC ${trackToDownload.isrc}, AlbumType ${trackToDownload.albumType}',
              );
            } else {
              _log.w('Unexpected track data type: ${trackData.runtimeType}');
            }
          } else {
            _log.w('Response does not contain track key');
          }
        } catch (e, stack) {
          _log.w('Failed to enrich metadata: $e');
          _log.w('Stack trace: $stack');
        }

        if (await shouldAbortWork('during metadata enrichment')) {
          return;
        }
      }

      _log.d('Track coverUrl after enrichment: ${trackToDownload.coverUrl}');

      final resolvedAlbumArtist = _resolveAlbumArtistForMetadata(
        trackToDownload,
        settings,
      );

      var quality = item.qualityOverride ?? state.audioQuality;
      if (quality == 'DEFAULT') quality = state.audioQuality;
      final isSafMode = _isSafMode(settings);
      final relativeOutputDir = isSafMode
          ? await _buildRelativeOutputDir(
              trackToDownload,
              settings.folderOrganization,
              separateSingles: settings.separateSingles,
              albumFolderStructure: settings.albumFolderStructure,
              createPlaylistFolder: settings.createPlaylistFolder,
              useAlbumArtistForFolders: settings.useAlbumArtistForFolders,
              usePrimaryArtistOnly: settings.usePrimaryArtistOnly,
              filterContributingArtistsInAlbumArtist:
                  settings.filterContributingArtistsInAlbumArtist,
              playlistName: item.playlistName,
            )
          : '';
      String? appOutputDir;
      final initialOutputDir = isSafMode
          ? relativeOutputDir
          : await _buildOutputDir(
              trackToDownload,
              settings.folderOrganization,
              separateSingles: settings.separateSingles,
              albumFolderStructure: settings.albumFolderStructure,
              createPlaylistFolder: settings.createPlaylistFolder,
              useAlbumArtistForFolders: settings.useAlbumArtistForFolders,
              usePrimaryArtistOnly: settings.usePrimaryArtistOnly,
              filterContributingArtistsInAlbumArtist:
                  settings.filterContributingArtistsInAlbumArtist,
              playlistName: item.playlistName,
            );
      var effectiveOutputDir = isSafMode
          ? _sanitizeSafRelativeDir(initialOutputDir)
          : initialOutputDir;
      var effectiveSafMode = isSafMode;

      String? safFileName;
      String? safBaseName;
      String safOutputExt = _determineOutputExt(quality, item.service);
      final baseFilenameFormat = _shouldTreatAsSingleRelease(trackToDownload)
          ? state.singleFilenameFormat
          : state.filenameFormat;
      final effectiveFilenameFormat = _filenameFormatForItem(
        item,
        baseFilenameFormat,
      );
      if (isSafMode) {
        safFileName = await _buildSafFileNameForItem(
          item,
          trackToDownload,
          filenameFormat: effectiveFilenameFormat,
          quality: quality,
          outputExt: safOutputExt,
        );
        safBaseName = safFileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      }
      String? finalSafFileName = safFileName;
      // Filled by the SAF embed op from the local temp so the final quality
      // probe doesn't have to copy the published file back out of SAF.
      Map<String, dynamic>? probedFinalMetadata;

      String? genre;
      String? label;
      String? copyright;
      final extensionState = ref.read(extensionProvider);
      final selectedExtensionDownloadProvider =
          settings.useExtensionProviders &&
          extensionState.extensions.any(
            (e) =>
                e.enabled &&
                e.hasDownloadProvider &&
                e.id.toLowerCase() == item.service.toLowerCase(),
          );
      final trackSource = (trackToDownload.source ?? '').trim().toLowerCase();
      final shouldSkipExtensionSongLinkPrelookup =
          trackSource.isNotEmpty &&
          extensionState.extensions.any(
            (e) =>
                e.enabled &&
                e.hasMetadataProvider &&
                e.id.toLowerCase() == trackSource,
          );

      String? deezerTrackId = await _resolveDeezerIdFromKnownOrIsrc(
        trackToDownload,
        item.id,
        lookupContext: 'ISRC',
      );
      if (await shouldAbortWork('during Deezer ISRC lookup')) {
        return;
      }

      // For tidal:/qobuz: tracks without ISRC, resolve ISRC from provider
      // API directly (faster than SongLink and avoids rate limits).
      final providerResolved = await _resolveDeezerIdViaProviderIfNeeded(
        trackToDownload,
        deezerTrackId,
        item.id,
      );
      trackToDownload = providerResolved.track;
      deezerTrackId = providerResolved.deezerTrackId;
      if (await shouldAbortWork('during provider ISRC resolution')) {
        return;
      }

      if (!selectedExtensionDownloadProvider &&
          deezerTrackId == null &&
          !shouldSkipExtensionSongLinkPrelookup &&
          trackToDownload.id.isNotEmpty &&
          !trackToDownload.id.startsWith('deezer:') &&
          !trackToDownload.id.startsWith('extension:') &&
          !trackToDownload.id.startsWith('tidal:') &&
          !trackToDownload.id.startsWith('qobuz:')) {
        final spotifyLookup = await _resolveSpotifyTrackViaDeezer(
          trackToDownload,
        );
        trackToDownload = spotifyLookup.track;
        deezerTrackId ??= spotifyLookup.deezerTrackId;

        if (await shouldAbortWork('during SongLink availability lookup')) {
          return;
        }
      } else if (selectedExtensionDownloadProvider && deezerTrackId == null) {
        _log.d(
          'Skipping Flutter SongLink Deezer prelookup for extension provider: ${item.service}',
        );
      } else if (shouldSkipExtensionSongLinkPrelookup &&
          deezerTrackId == null) {
        _log.d(
          'Skipping Flutter SongLink Deezer prelookup for extension-sourced track; backend metadata enrichment will resolve identifiers first',
        );
      }

      // Genre/label/copyright are only consumed at embed time (the payload
      // copy is just echoed back in the response), so this lookup overlaps
      // with the download instead of delaying its start; it is awaited right
      // after the download returns.
      final extendedMetadataFuture =
          _loadExtendedMetadataForDeezerId(deezerTrackId).catchError((
            Object e,
          ) {
            _log.w('Extended metadata lookup failed: $e');
            return null;
          });

      Map<String, dynamic> result;

      final hasActiveExtensions = extensionState.extensions.any(
        (e) => e.enabled,
      );
      final useExtensions =
          settings.useExtensionProviders && hasActiveExtensions;

      Future<Map<String, dynamic>> runDownload({
        required bool useSaf,
        required String outputDir,
      }) async {
        final outputExt = safOutputExt;
        final shouldUseExtensions = useExtensions;
        final shouldUseFallback = state.autoFallback;

        if (shouldUseExtensions) {
          _log.d('Using extension providers for download');
          _log.d(
            'Quality: $quality${item.qualityOverride != null ? ' (override)' : ''}',
          );
        } else if (shouldUseFallback) {
          _log.d('Using auto-fallback mode');
          _log.d(
            'Quality: $quality${item.qualityOverride != null ? ' (override)' : ''}',
          );
        }

        if (!useSaf) {
          await _ensureDirExists(outputDir, label: 'Output folder');
        }

        _log.d('Output dir: $outputDir');

        final payload = _buildDownloadRequestPayload(
          track: trackToDownload,
          item: item,
          settings: settings,
          extensionState: extensionState,
          quality: quality,
          filenameFormat: effectiveFilenameFormat,
          outputDir: outputDir,
          outputExt: outputExt,
          useSaf: useSaf,
          safFileName: safFileName,
          deezerTrackId: deezerTrackId,
          genre: genre,
          label: label,
          copyright: copyright,
        );

        return PlatformBridge.downloadByStrategy(
          payload: payload,
          useExtensions: shouldUseExtensions,
          useFallback: shouldUseFallback,
        );
      }

      if (await shouldAbortWork('before native download start')) {
        return;
      }

      result = await runDownload(
        useSaf: effectiveSafMode,
        outputDir: effectiveOutputDir,
      );

      if (effectiveSafMode &&
          result['success'] != true &&
          _isSafWriteFailure(result)) {
        if (_isLocallyCancelled(item.id)) {
          _log.i('Download was cancelled before SAF fallback, skipping');
          return;
        }
        _log.w('SAF write failed, retrying with app-private storage');
        appOutputDir ??= await _buildOutputDir(
          trackToDownload,
          settings.folderOrganization,
          separateSingles: settings.separateSingles,
          albumFolderStructure: settings.albumFolderStructure,
          createPlaylistFolder: settings.createPlaylistFolder,
          useAlbumArtistForFolders: settings.useAlbumArtistForFolders,
          usePrimaryArtistOnly: settings.usePrimaryArtistOnly,
          filterContributingArtistsInAlbumArtist:
              settings.filterContributingArtistsInAlbumArtist,
          playlistName: item.playlistName,
        );
        final fallbackResult = await runDownload(
          useSaf: false,
          outputDir: appOutputDir,
        );
        if (fallbackResult['success'] == true) {
          effectiveSafMode = false;
          effectiveOutputDir = appOutputDir;
          finalSafFileName = null;
          result = fallbackResult;
        }
      }

      _log.d('Result: $result');

      final extendedMetadata = await extendedMetadataFuture;
      if (extendedMetadata != null) {
        genre = extendedMetadata.genre;
        label = extendedMetadata.label;
        copyright = extendedMetadata.copyright;
      }

      final resultFilePath = result['file_path'] as String?;
      final resultFileToCleanup =
          (resultFilePath != null && result['success'] == true)
          ? resultFilePath
          : null;
      if (await shouldAbortWork(
        'after result',
        deleteFileOnAbort: resultFileToCleanup,
      )) {
        return;
      }

      if (result['success'] == true) {
        var filePath = result['file_path'] as String?;
        final reportedFileName = result['file_name'] as String?;
        if (effectiveSafMode &&
            reportedFileName != null &&
            reportedFileName.isNotEmpty) {
          finalSafFileName = reportedFileName;
        }

        final wasExisting = result['already_exists'] == true;
        if (wasExisting) {
          _log.i('File already exists in library: $filePath');
        }

        _log.i('Download success, file: $filePath');

        final actualBitDepth = result['actual_bit_depth'] as int?;
        final actualSampleRate = result['actual_sample_rate'] as int?;
        String actualQuality = quality;

        if (actualBitDepth != null && actualBitDepth > 0) {
          final sampleRateKHz = actualSampleRate != null && actualSampleRate > 0
              ? (actualSampleRate / 1000).toStringAsFixed(
                  actualSampleRate % 1000 == 0 ? 0 : 1,
                )
              : '?';
          actualQuality = '$actualBitDepth-bit/${sampleRateKHz}kHz';
          _log.i('Actual quality: $actualQuality');
        }

        final actualService =
            ((result['service'] as String?)?.toLowerCase()) ??
            item.service.toLowerCase();
        final resultOutputExt = _downloadResultOutputExt(
          result,
          filePath: filePath,
        );
        final resultAudioFormat = normalizeAudioFormatValue(
          result['audio_codec']?.toString() ??
              result['actual_audio_codec']?.toString(),
        );
        final resultIsLossyAudio = isLossyAudioFormat(resultAudioFormat);
        final requiresContainerConversion =
            result['requires_container_conversion'] == true ||
            result['requiresContainerConversion'] == true ||
            (!resultIsLossyAudio &&
                _shouldRequestContainerConversion(actualService, safOutputExt));
        final preferredOutputExt = _extensionPreferredOutputExt(actualService);
        final shouldPreserveNativeM4a =
            !requiresContainerConversion &&
            (resultOutputExt == '.m4a' ||
                resultOutputExt == '.mp4' ||
                preferredOutputExt == '.m4a' ||
                preferredOutputExt == '.mp4' ||
                _extensionPreservesNativeOutputExt(actualService, '.m4a') ||
                _extensionPreservesNativeOutputExt(actualService, '.mp4'));
        final decryptionDescriptor =
            DownloadDecryptionDescriptor.fromDownloadResult(result);
        trackToDownload = _buildTrackForMetadataEmbedding(
          trackToDownload,
          result,
          resolvedAlbumArtist,
        );
        _log.d(
          'Track coverUrl after download result: ${trackToDownload.coverUrl}',
        );

        if (!wasExisting && decryptionDescriptor != null && filePath != null) {
          _log.i(
            'Encrypted stream detected, decrypting via ${decryptionDescriptor.normalizedStrategy}...',
          );
          updateItemStatus(item.id, DownloadStatus.finalizing, progress: 0.9);

          final isSafSource = effectiveSafMode && isContentUri(filePath);
          final decryptOutcome = await _finalizeDecryption(
            result: result,
            filePath: filePath,
            storageMode: effectiveSafMode ? 'saf' : 'app',
            downloadTreeUri: settings.downloadTreeUri,
            safRelativeDir: effectiveOutputDir,
            baseName: safBaseName ?? 'track',
            extFallback: '.flac',
            repairAc4: true,
          );
          if (decryptOutcome.path == null) {
            final String errorMsg;
            switch (decryptOutcome.failStage) {
              case DownloadQueueNotifier._decryptStageSafAccess:
                _log.e('Failed to copy encrypted SAF file to temp for decrypt');
                errorMsg = 'Failed to access encrypted SAF file';
                break;
              case DownloadQueueNotifier._decryptStageSafWrite:
                _log.e('Failed to write decrypted stream back to SAF');
                errorMsg = 'Failed to write decrypted file to storage';
                break;
              default:
                _log.e(
                  isSafSource
                      ? 'FFmpeg decrypt failed for SAF file'
                      : 'FFmpeg decrypt failed for local file',
                );
                errorMsg = 'Failed to decrypt encrypted stream';
                break;
            }
            updateItemStatus(
              item.id,
              DownloadStatus.failed,
              error: errorMsg,
              errorType: DownloadErrorType.unknown,
            );
            return;
          }
          filePath = decryptOutcome.path;
          if (decryptOutcome.newFileName != null) {
            finalSafFileName = decryptOutcome.newFileName;
          }
          _log.i(
            isSafSource
                ? 'SAF decryption completed'
                : 'Local decryption completed',
          );
        }

        final isContentUriPath = filePath != null && isContentUri(filePath);
        final mimeType = isContentUriPath
            ? await _getSafMimeType(filePath)
            : null;
        final isM4aFile =
            filePath != null &&
            (filePath.endsWith('.m4a') ||
                filePath.endsWith('.mp4') ||
                resultOutputExt == '.m4a' ||
                resultOutputExt == '.mp4' ||
                (mimeType != null && mimeType.contains('mp4')));
        final isFlacFile =
            filePath != null &&
            (filePath.endsWith('.flac') ||
                resultOutputExt == '.flac' ||
                (mimeType != null && mimeType.contains('flac')));
        final shouldForceDashSafM4aHandling =
            !wasExisting &&
            isContentUriPath &&
            effectiveSafMode &&
            _downloadProviderReplacesLegacyProvider(actualService, 'tidal') &&
            filePath.endsWith('.flac') &&
            (mimeType == null || mimeType.contains('flac'));

        if (shouldForceDashSafM4aHandling) {
          _log.w(
            'SAF file is labeled FLAC but backend returned DASH/M4A stream; converting it back to FLAC.',
          );
        }

        if (isM4aFile || shouldForceDashSafM4aHandling) {
          final currentFilePath = filePath;

          if (isContentUriPath && effectiveSafMode) {
            if (quality == 'HIGH') {
              final tidalHighFormat = settings.tidalHighFormat;
              _log.i(
                'Lossy 320kbps quality (SAF), converting M4A to $tidalHighFormat...',
              );

              final format = lossyFormatForSetting(tidalHighFormat);
              final displayFormat = displayFormatForLossyFormat(format);
              final newExt = lossyExtensionForFormat(format);
              final newFileName = '${safBaseName ?? 'track'}$newExt';
              var opStarted = false;
              var convertFailed = false;
              try {
                final newUri = await _replaceSafFileVia(
                  uri: currentFilePath,
                  treeUri: settings.downloadTreeUri,
                  relativeDir: effectiveOutputDir,
                  op: (tempPath, addCleanup) async {
                    opStarted = true;
                    updateItemStatus(
                      item.id,
                      DownloadStatus.finalizing,
                      progress: 0.95,
                    );
                    final convertedPath = await FFmpegService.convertM4aToLossy(
                      tempPath,
                      format: format,
                      bitrate: tidalHighFormat,
                      deleteOriginal: false,
                    );
                    if (convertedPath == null) {
                      convertFailed = true;
                      return null;
                    }
                    addCleanup(convertedPath);
                    _log.i(
                      'Successfully converted M4A to $format (temp): $convertedPath',
                    );
                    _log.i('Embedding metadata to $format...');
                    updateItemStatus(
                      item.id,
                      DownloadStatus.finalizing,
                      progress: 0.99,
                    );

                    final backendGenre = result['genre'] as String?;
                    final backendLabel = result['label'] as String?;
                    final backendCopyright = result['copyright'] as String?;

                    await _embedMetadataToFile(
                      convertedPath,
                      trackToDownload,
                      format: metadataFormatForLossyFormat(format),
                      genre: backendGenre ?? genre,
                      label: backendLabel ?? label,
                      copyright: backendCopyright,
                      downloadService: item.service,
                    );

                    return (convertedPath, newFileName);
                  },
                );

                if (newUri != null) {
                  filePath = newUri;
                  finalSafFileName = newFileName;
                  final bitrateDisplay = tidalHighFormat.contains('_')
                      ? '${tidalHighFormat.split('_').last}kbps'
                      : '320kbps';
                  actualQuality = '$displayFormat $bitrateDisplay';
                } else if (convertFailed) {
                  _log.w('M4A to $format conversion failed, keeping M4A file');
                  actualQuality = 'AAC 320kbps';
                } else if (opStarted) {
                  _log.w(
                    'Failed to write converted $format to SAF, keeping M4A',
                  );
                  actualQuality = 'AAC 320kbps';
                }
              } catch (e) {
                _log.w('SAF M4A conversion failed: $e');
                actualQuality = 'AAC 320kbps';
              }
            } else if (shouldPreserveNativeM4a) {
              // Decrypted streams are already in their final format.
              // Converting e.g. eac3 M4A to FLAC would produce fake upscaled output.
              _log.d(
                'M4A/MP4 file detected (SAF), preserving native container...',
              );
              final preserveExt = currentFilePath.toLowerCase().endsWith('.mp4')
                  ? '.mp4'
                  : '.m4a';
              final newFileName = '${safBaseName ?? 'track'}$preserveExt';
              var opStarted = false;
              try {
                final newUri = await _replaceSafFileVia(
                  uri: currentFilePath,
                  treeUri: settings.downloadTreeUri,
                  relativeDir: effectiveOutputDir,
                  op: (tempPath, _) async {
                    opStarted = true;
                    if (metadataEmbeddingEnabled) {
                      updateItemStatus(
                        item.id,
                        DownloadStatus.finalizing,
                        progress: 0.99,
                      );
                      final finalTrack = _buildTrackForMetadataEmbedding(
                        trackToDownload,
                        result,
                        resolvedAlbumArtist,
                      );
                      final backendGenre = result['genre'] as String?;
                      final backendLabel = result['label'] as String?;
                      final backendCopyright = result['copyright'] as String?;

                      await _embedMetadataToFile(
                        tempPath,
                        finalTrack,
                        format: 'm4a',
                        genre: backendGenre ?? genre,
                        label: backendLabel ?? label,
                        copyright: backendCopyright,
                        downloadService: item.service,
                        writeExternalLrc: false,
                      );
                    }
                    return (tempPath, newFileName);
                  },
                );

                if (newUri != null) {
                  filePath = newUri;
                  finalSafFileName = newFileName;
                } else if (opStarted) {
                  _log.w('Failed to write M4A to SAF, keeping original');
                }
              } catch (e) {
                _log.w('SAF native M4A handling failed: $e');
              }
            } else {
              _log.d('M4A file detected (SAF), converting to FLAC...');
              String? branch;
              String? producedFileName;
              try {
                final newUri = await _replaceSafFileVia(
                  uri: currentFilePath,
                  treeUri: settings.downloadTreeUri,
                  relativeDir: effectiveOutputDir,
                  op: (tempPath, addCleanup) async {
                    final length = await File(tempPath).length();
                    if (length < 1024) {
                      _log.w(
                        'Temp M4A is too small (<1KB), skipping conversion',
                      );
                      branch = 'skip';
                      return null;
                    }
                    final codec = await FFmpegService.probePrimaryAudioCodec(
                      tempPath,
                    );
                    final isAlreadyNativeFlac =
                        codec == 'flac' &&
                        await FFmpegService.isNativeFlacFile(tempPath);
                    if (!FFmpegService.isLosslessAudioCodec(codec)) {
                      _log.d(
                        'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
                        'no FLAC container conversion needed.',
                      );
                      branch = 'preserve';
                      final preserveExt = resultOutputExt == '.mp4'
                          ? '.mp4'
                          : '.m4a';
                      final newFileName =
                          '${safBaseName ?? 'track'}$preserveExt';
                      producedFileName = newFileName;
                      return (tempPath, newFileName);
                    } else if (isAlreadyNativeFlac) {
                      _log.d(
                        'Native FLAC payload detected in SAF temp file; '
                        'publishing as FLAC and embedding metadata.',
                      );
                      branch = 'nativeFlac';
                      final finalTrack = _buildTrackForMetadataEmbedding(
                        trackToDownload,
                        result,
                        resolvedAlbumArtist,
                      );

                      final backendGenre = result['genre'] as String?;
                      final backendLabel = result['label'] as String?;
                      final backendCopyright = result['copyright'] as String?;

                      await _embedMetadataToFile(
                        tempPath,
                        finalTrack,
                        format: 'flac',
                        genre: backendGenre ?? genre,
                        label: backendLabel ?? label,
                        copyright: backendCopyright,
                        downloadService: item.service,
                        writeExternalLrc: false,
                      );

                      final newFileName = '${safBaseName ?? 'track'}.flac';
                      producedFileName = newFileName;
                      return (tempPath, newFileName);
                    } else {
                      updateItemStatus(
                        item.id,
                        DownloadStatus.finalizing,
                        progress: 0.95,
                      );
                      final flacPath = await FFmpegService.convertM4aToFlac(
                        tempPath,
                      );
                      if (flacPath == null) {
                        _log.w(
                          'FFmpeg conversion returned null, keeping M4A file',
                        );
                        branch = 'convertFailed';
                        return null;
                      }
                      addCleanup(flacPath);
                      _log.d('Converted to FLAC (temp): $flacPath');
                      _log.d(
                        'Embedding metadata and cover to converted FLAC...',
                      );
                      final finalTrack = _buildTrackForMetadataEmbedding(
                        trackToDownload,
                        result,
                        resolvedAlbumArtist,
                      );

                      final backendGenre = result['genre'] as String?;
                      final backendLabel = result['label'] as String?;
                      final backendCopyright = result['copyright'] as String?;

                      await _embedMetadataToFile(
                        flacPath,
                        finalTrack,
                        format: 'flac',
                        genre: backendGenre ?? genre,
                        label: backendLabel ?? label,
                        copyright: backendCopyright,
                        downloadService: item.service,
                        writeExternalLrc: false,
                      );

                      final newFileName = '${safBaseName ?? 'track'}.flac';
                      branch = 'convert';
                      producedFileName = newFileName;
                      return (flacPath, newFileName);
                    }
                  },
                );

                if (newUri != null) {
                  filePath = newUri;
                  finalSafFileName = producedFileName;
                } else if (branch == 'nativeFlac') {
                  _log.w('Failed to write native FLAC to SAF');
                } else if (branch == 'convert') {
                  _log.w('Failed to write FLAC to SAF, keeping M4A');
                }
              } catch (e) {
                _log.w('SAF M4A->FLAC conversion failed: $e');
              }
            }
          } else {
            if (quality == 'HIGH') {
              final tidalHighFormat = settings.tidalHighFormat;
              _log.i(
                'Lossy 320kbps quality download, converting M4A to $tidalHighFormat...',
              );

              try {
                updateItemStatus(
                  item.id,
                  DownloadStatus.finalizing,
                  progress: 0.95,
                );

                final format = lossyFormatForSetting(tidalHighFormat);
                final displayFormat = displayFormatForLossyFormat(format);
                final convertedPath = await FFmpegService.convertM4aToLossy(
                  currentFilePath,
                  format: format,
                  bitrate: tidalHighFormat,
                  deleteOriginal: true,
                );

                if (convertedPath != null) {
                  filePath = convertedPath;
                  final bitrateDisplay = tidalHighFormat.contains('_')
                      ? '${tidalHighFormat.split('_').last}kbps'
                      : '320kbps';
                  actualQuality = '$displayFormat $bitrateDisplay';
                  _log.i(
                    'Successfully converted M4A to $format: $convertedPath',
                  );

                  _log.i('Embedding metadata to $format...');
                  updateItemStatus(
                    item.id,
                    DownloadStatus.finalizing,
                    progress: 0.99,
                  );

                  final backendGenre = result['genre'] as String?;
                  final backendLabel = result['label'] as String?;
                  final backendCopyright = result['copyright'] as String?;

                  await _embedMetadataToFile(
                    convertedPath,
                    trackToDownload,
                    format: metadataFormatForLossyFormat(format),
                    genre: backendGenre ?? genre,
                    label: backendLabel ?? label,
                    copyright: backendCopyright,
                    downloadService: item.service,
                  );
                  _log.d('Metadata embedded successfully');
                } else {
                  _log.w('M4A to $format conversion failed, keeping M4A file');
                  actualQuality = 'AAC 320kbps';
                }
              } catch (e) {
                _log.w('M4A conversion process failed: $e, keeping M4A file');
                actualQuality = 'AAC 320kbps';
              }
            } else if (shouldPreserveNativeM4a) {
              _log.d('M4A/MP4 file detected, preserving native container...');

              try {
                var targetPath = currentFilePath;
                final file = File(targetPath);
                if (!await file.exists()) {
                  _log.e('File does not exist at path: $filePath');
                } else {
                  if (!(targetPath.toLowerCase().endsWith('.m4a') ||
                      targetPath.toLowerCase().endsWith('.mp4'))) {
                    final renamedPath = targetPath.replaceAll(
                      RegExp(r'\.[^.]+$'),
                      '.m4a',
                    );
                    final finalRenamedPath = renamedPath == targetPath
                        ? '$targetPath.m4a'
                        : renamedPath;
                    await file.rename(finalRenamedPath);
                    targetPath = finalRenamedPath;
                    filePath = finalRenamedPath;
                  } else {
                    filePath = targetPath;
                  }

                  if (metadataEmbeddingEnabled) {
                    updateItemStatus(
                      item.id,
                      DownloadStatus.finalizing,
                      progress: 0.99,
                    );
                    final finalTrack = _buildTrackForMetadataEmbedding(
                      trackToDownload,
                      result,
                      resolvedAlbumArtist,
                    );

                    final backendGenre = result['genre'] as String?;
                    final backendLabel = result['label'] as String?;
                    final backendCopyright = result['copyright'] as String?;

                    await _embedMetadataToFile(
                      targetPath,
                      finalTrack,
                      format: 'm4a',
                      genre: backendGenre ?? genre,
                      label: backendLabel ?? label,
                      copyright: backendCopyright,
                      downloadService: item.service,
                    );
                  }
                }
              } catch (e) {
                _log.w('Native M4A handling failed: $e');
              }
            } else {
              _log.d(
                'M4A file detected (Hi-Res DASH stream), attempting conversion to FLAC...',
              );

              try {
                final file = File(currentFilePath);
                if (!await file.exists()) {
                  _log.e('File does not exist at path: $filePath');
                } else {
                  final length = await file.length();
                  _log.i('File size before conversion: ${length / 1024} KB');

                  if (length < 1024) {
                    _log.w(
                      'File is too small (<1KB), skipping conversion. Download might be corrupt.',
                    );
                  } else {
                    final codec = await FFmpegService.probePrimaryAudioCodec(
                      currentFilePath,
                    );
                    final isAlreadyNativeFlac =
                        codec == 'flac' &&
                        await FFmpegService.isNativeFlacFile(currentFilePath);
                    if (!FFmpegService.isLosslessAudioCodec(codec)) {
                      _log.d(
                        'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
                        'no FLAC container conversion needed.',
                      );
                    } else if (isAlreadyNativeFlac) {
                      _log.d(
                        'Native FLAC payload detected; ensuring .flac '
                        'extension and embedding metadata.',
                      );
                      var flacPath = currentFilePath;
                      if (!currentFilePath.toLowerCase().endsWith('.flac')) {
                        final renamedPath = currentFilePath.replaceAll(
                          RegExp(r'\.[^.]+$'),
                          '.flac',
                        );
                        final targetPath = renamedPath == currentFilePath
                            ? '$currentFilePath.flac'
                            : renamedPath;
                        await File(currentFilePath).rename(targetPath);
                        flacPath = targetPath;
                        filePath = targetPath;
                      }

                      final finalTrack = _buildTrackForMetadataEmbedding(
                        trackToDownload,
                        result,
                        resolvedAlbumArtist,
                      );

                      final backendGenre = result['genre'] as String?;
                      final backendLabel = result['label'] as String?;
                      final backendCopyright = result['copyright'] as String?;

                      await _embedMetadataToFile(
                        flacPath,
                        finalTrack,
                        format: 'flac',
                        genre: backendGenre ?? genre,
                        label: backendLabel ?? label,
                        copyright: backendCopyright,
                        downloadService: item.service,
                      );
                    } else {
                      updateItemStatus(
                        item.id,
                        DownloadStatus.finalizing,
                        progress: 0.95,
                      );
                      final flacPath = await FFmpegService.convertM4aToFlac(
                        currentFilePath,
                      );

                      if (flacPath != null) {
                        filePath = flacPath;
                        _log.d('Converted to FLAC: $flacPath');

                        _log.d(
                          'Embedding metadata and cover to converted FLAC...',
                        );
                        try {
                          final finalTrack = _buildTrackForMetadataEmbedding(
                            trackToDownload,
                            result,
                            resolvedAlbumArtist,
                          );

                          final backendGenre = result['genre'] as String?;
                          final backendLabel = result['label'] as String?;
                          final backendCopyright =
                              result['copyright'] as String?;

                          if (backendGenre != null ||
                              backendLabel != null ||
                              backendCopyright != null) {
                            _log.d(
                              'Extended metadata from backend - Genre: $backendGenre, Label: $backendLabel, Copyright: $backendCopyright',
                            );
                          }

                          await _embedMetadataToFile(
                            flacPath,
                            finalTrack,
                            format: 'flac',
                            genre: backendGenre ?? genre,
                            label: backendLabel ?? label,
                            copyright: backendCopyright,
                            downloadService: item.service,
                          );
                          _log.d('Metadata and cover embedded successfully');
                        } catch (e) {
                          _log.w('Warning: Failed to embed metadata/cover: $e');
                        }
                      } else {
                        _log.w(
                          'FFmpeg conversion returned null, keeping M4A file',
                        );
                      }
                    }
                  }
                }
              } catch (e) {
                _log.w(
                  'FFmpeg conversion process failed: $e, keeping M4A file',
                );
              }
            }
          }
        } else if (metadataEmbeddingEnabled &&
            isContentUriPath &&
            effectiveSafMode &&
            !isM4aFile &&
            !wasExisting) {
          final currentFilePath = filePath;
          final isOpusFile =
              filePath.endsWith('.opus') ||
              filePath.endsWith('.ogg') ||
              resultOutputExt == '.opus' ||
              resultOutputExt == '.ogg';
          final isMp3File =
              filePath.endsWith('.mp3') || resultOutputExt == '.mp3';
          final ext = isOpusFile
              ? (resultOutputExt == '.ogg' ? '.ogg' : '.opus')
              : isMp3File
              ? '.mp3'
              : '.flac';
          final formatName = isOpusFile
              ? 'Opus'
              : isMp3File
              ? 'MP3'
              : 'FLAC';
          _log.d(
            'SAF $formatName detected, embedding metadata and cover via temp file...',
          );
          final newFileName = '${safBaseName ?? 'track'}$ext';
          var opStarted = false;
          try {
            final newUri = await _replaceSafFileVia(
              uri: currentFilePath,
              treeUri: settings.downloadTreeUri,
              relativeDir: effectiveOutputDir,
              op: (tempPath, _) async {
                opStarted = true;
                updateItemStatus(
                  item.id,
                  DownloadStatus.finalizing,
                  progress: 0.99,
                );

                final finalTrack = _buildTrackForMetadataEmbedding(
                  trackToDownload,
                  result,
                  resolvedAlbumArtist,
                );
                final backendGenre = result['genre'] as String?;
                final backendLabel = result['label'] as String?;
                final backendCopyright = result['copyright'] as String?;

                // writeExternalLrc: false — tempPath lives in the cache dir,
                // so a sidecar .lrc written next to it would be orphaned;
                // the SAF .lrc is written by _saveExternalLrc after publish,
                // reusing the LRC fetched here via result['lyrics_lrc'].
                final embedFormat = isMp3File
                    ? 'mp3'
                    : isOpusFile
                    ? 'opus'
                    : 'flac';
                final fetchedLrc = await _embedMetadataToFile(
                  tempPath,
                  finalTrack,
                  format: embedFormat,
                  genre: backendGenre ?? genre,
                  label: backendLabel ?? label,
                  copyright: backendCopyright,
                  downloadService: item.service,
                  writeExternalLrc: false,
                );
                final existingLrc = result['lyrics_lrc'] as String?;
                if ((existingLrc == null || existingLrc.isEmpty) &&
                    fetchedLrc != null &&
                    fetchedLrc.isNotEmpty) {
                  result['lyrics_lrc'] = fetchedLrc;
                }

                // Probe quality from the local temp now: the same probe on
                // the published content:// URI would copy the whole file
                // out of SAF again just to read a few header bytes.
                try {
                  probedFinalMetadata = await PlatformBridge.readFileMetadata(
                    tempPath,
                  );
                } catch (_) {}

                return (tempPath, newFileName);
              },
            );

            if (newUri != null) {
              filePath = newUri;
              finalSafFileName = newFileName;
              _log.d('SAF $formatName metadata embedding completed');
            } else if (opStarted) {
              _log.w(
                'Failed to write metadata-updated $formatName back to SAF',
              );
            }
          } catch (e) {
            _log.w('SAF $formatName metadata embedding failed: $e');
          }
        } else if (metadataEmbeddingEnabled &&
            !isContentUriPath &&
            !effectiveSafMode &&
            isFlacFile &&
            !wasExisting &&
            decryptionDescriptor != null) {
          _log.d(
            'Local FLAC after decrypt detected, embedding metadata and cover...',
          );
          try {
            updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.99,
            );

            final finalTrack = _buildTrackForMetadataEmbedding(
              trackToDownload,
              result,
              resolvedAlbumArtist,
            );
            final backendGenre = result['genre'] as String?;
            final backendLabel = result['label'] as String?;
            final backendCopyright = result['copyright'] as String?;

            await _embedMetadataToFile(
              filePath,
              finalTrack,
              format: 'flac',
              genre: backendGenre ?? genre,
              label: backendLabel ?? label,
              copyright: backendCopyright,
              downloadService: item.service,
            );
            _log.d('Local FLAC metadata embedding completed');
          } catch (e) {
            _log.w('Local FLAC metadata embedding failed: $e');
          }
        }

        if (await shouldAbortWork(
          'during finalization',
          deleteFileOnAbort: filePath,
        )) {
          return;
        }

        if (effectiveSafMode &&
            filePath != null &&
            filePath.isNotEmpty &&
            !isContentUri(filePath) &&
            settings.downloadTreeUri.isNotEmpty) {
          final fallbackName = (finalSafFileName ?? safFileName ?? '').trim();
          if (fallbackName.isNotEmpty) {
            try {
              final resolved = await PlatformBridge.resolveSafFile(
                treeUri: settings.downloadTreeUri,
                relativeDir: effectiveOutputDir,
                fileName: fallbackName,
              );
              final resolvedUri = (resolved['uri'] as String? ?? '').trim();
              final resolvedRelativeDir =
                  (resolved['relative_dir'] as String? ?? '').trim();
              if (resolvedUri.isNotEmpty && isContentUri(resolvedUri)) {
                _log.w('Recovered SAF URI from transient path: $filePath');
                filePath = resolvedUri;
                finalSafFileName = fallbackName;
                if (resolvedRelativeDir.isNotEmpty) {
                  effectiveOutputDir = resolvedRelativeDir;
                }
              } else {
                _log.w(
                  'Failed to recover SAF URI (fileName=$fallbackName, dir=$effectiveOutputDir)',
                );
              }
            } catch (e) {
              _log.w('SAF URI recovery failed: $e');
            }
          } else {
            _log.w(
              'SAF download returned non-URI path without filename metadata: $filePath',
            );
          }
        }

        if (filePath != null) {
          final postProcessedPath = await _runPostProcessingHooks(
            filePath,
            trackToDownload,
          );
          if (postProcessedPath != null && postProcessedPath.isNotEmpty) {
            filePath = postProcessedPath;
            result['file_path'] = postProcessedPath;
          }
        }

        if (filePath != null && item.preserveQualityVariant) {
          final variantOutcome = await _finalizeQualityVariantFilename(
            item: item,
            result: result,
            filePath: filePath,
            storageMode: effectiveSafMode ? 'saf' : 'app',
            downloadTreeUri: settings.downloadTreeUri,
            safRelativeDir: effectiveOutputDir,
            fileName: finalSafFileName ?? safFileName,
          );
          filePath = variantOutcome.filePath;
          if (variantOutcome.fileName != null) {
            finalSafFileName = variantOutcome.fileName;
          }
          if (variantOutcome.metadata != null) {
            probedFinalMetadata = variantOutcome.metadata;
          }
        }

        if (normalizeOptionalString(filePath) == null) {
          throw StateError(
            'Download backend reported success without a final file path',
          );
        }

        if (effectiveSafMode && filePath != null && isContentUri(filePath)) {
          await _saveExternalLrc(
            result: result,
            settings: settings,
            extensionState: extensionState,
            track: trackToDownload,
            service: item.service,
            filePath: filePath,
            storageMode: 'saf',
            downloadTreeUri: settings.downloadTreeUri,
            safRelativeDir: effectiveOutputDir,
            resolveBaseName: () async {
              final currentFinalName = finalSafFileName;
              return currentFinalName != null
                  ? currentFinalName.replaceFirst(RegExp(r'\.[^.]+$'), '')
                  : safBaseName ??
                        await PlatformBridge.sanitizeFilename(
                          '${trackToDownload.artistName} - ${trackToDownload.name}',
                        );
            },
            onFetchError: (e) =>
                _log.w('Failed to fetch lyrics for external LRC: $e'),
          );
        }

        // Album ReplayGain: update the accumulator path to the final file
        // location.  For SAF downloads the metadata was embedded on a temp
        // copy, so the stored path still points there.  Replace it with the
        // actual output path (SAF content URI or local path) so the later
        // album-gain writer targets the correct file.
        if (filePath != null) {
          _updateAlbumRgFilePath(trackToDownload, filePath);
        }

        // Album ReplayGain: check if all album tracks are now complete and,
        // if so, compute and write album gain/peak to every track file.
        try {
          await _checkAndWriteAlbumReplayGain(trackToDownload);
        } catch (e) {
          _log.w('Album ReplayGain check failed: $e');
        }

        final historyNotifier = ref.read(downloadHistoryProvider.notifier);
        final existingInHistory = filePath == null
            ? null
            : await historyNotifier.getByFilePathAsync(filePath);

        if (wasExisting && existingInHistory != null) {
          _log.i(
            'Track file already exists in library; refreshing its history metadata',
          );
        }

        if (filePath != null) {
          final historyFilePath = filePath;
          final backendBitDepth = result['actual_bit_depth'] as int?;
          final backendSampleRate = result['actual_sample_rate'] as int?;
          final backendFormat =
              normalizeAudioFormatValue(
                result['audio_codec']?.toString() ??
                    result['format']?.toString(),
              ) ??
              normalizeAudioFormatValue(audioFormatForPath(filePath));
          final backendBitrateKbps = readPositiveBitrateKbps(
            result['bitrate'] ?? result['actual_bitrate'],
          );
          final backendGenre = result['genre'] as String?;
          final backendLabel = result['label'] as String?;
          final backendCopyright = result['copyright'] as String?;
          final effectiveGenre =
              normalizeOptionalString(backendGenre) ??
              normalizeOptionalString(genre) ??
              normalizeOptionalString(existingInHistory?.genre);
          final effectiveLabel =
              normalizeOptionalString(backendLabel) ??
              normalizeOptionalString(label) ??
              normalizeOptionalString(existingInHistory?.label);
          final effectiveCopyright =
              normalizeOptionalString(backendCopyright) ??
              normalizeOptionalString(copyright) ??
              normalizeOptionalString(existingInHistory?.copyright);

          int? finalBitDepth = backendBitDepth;
          int? finalSampleRate = backendSampleRate;
          String? finalFormat = backendFormat;
          int? finalBitrateKbps = isLossyAudioFormat(finalFormat)
              ? backendBitrateKbps
              : null;
          final lowerFilePath = filePath.toLowerCase();
          final canProbeFinalMetadata =
              filePath.startsWith('content://') ||
              lowerFilePath.endsWith('.flac') ||
              lowerFilePath.endsWith('.m4a') ||
              lowerFilePath.endsWith('.mp4') ||
              lowerFilePath.endsWith('.aac') ||
              lowerFilePath.endsWith('.mp3') ||
              lowerFilePath.endsWith('.opus') ||
              lowerFilePath.endsWith('.ogg');

          if (canProbeFinalMetadata) {
            try {
              final probed = probedFinalMetadata;
              final metadata = (probed != null && probed['error'] == null)
                  ? probed
                  : await PlatformBridge.readFileMetadata(filePath);
              if (metadata['error'] == null) {
                final probedBitDepth = metadata['bit_depth'] is num
                    ? (metadata['bit_depth'] as num).toInt()
                    : int.tryParse(metadata['bit_depth']?.toString() ?? '');
                final probedSampleRate = metadata['sample_rate'] is num
                    ? (metadata['sample_rate'] as num).toInt()
                    : int.tryParse(metadata['sample_rate']?.toString() ?? '');

                if (probedBitDepth != null && probedBitDepth > 0) {
                  finalBitDepth = probedBitDepth;
                }
                if (probedSampleRate != null && probedSampleRate > 0) {
                  finalSampleRate = probedSampleRate;
                }
                final probedFormat = normalizeAudioFormatValue(
                  metadata['audio_codec']?.toString() ??
                      metadata['format']?.toString(),
                );
                if (probedFormat != null) {
                  finalFormat = probedFormat;
                }
                final probedBitrateKbps = readPositiveBitrateKbps(
                  metadata['bitrate'] ?? metadata['bit_rate'],
                );
                if (probedBitrateKbps != null &&
                    isLossyAudioFormat(finalFormat)) {
                  finalBitrateKbps = probedBitrateKbps;
                }

                final resolvedQuality = resolveDisplayQuality(
                  filePath: filePath,
                  fileName: finalSafFileName,
                  detectedFormat: finalFormat,
                  bitDepth: finalBitDepth,
                  sampleRate: finalSampleRate,
                  bitrateKbps: finalBitrateKbps,
                  storedQuality: actualQuality,
                );
                if (resolvedQuality != null) {
                  actualQuality = resolvedQuality;
                }
              }
            } catch (e) {
              _log.d('Final audio metadata probe failed for $filePath: $e');
            }
          }

          _log.d('Saving to history - coverUrl: ${trackToDownload.coverUrl}');

          final isLossyOutput =
              isLossyAudioFormat(finalFormat) ||
              lowerFilePath.endsWith('.mp3') ||
              lowerFilePath.endsWith('.opus') ||
              lowerFilePath.endsWith('.ogg');
          final historyBitDepth = isLossyOutput ? null : finalBitDepth;
          final historySampleRate = isLossyOutput ? null : finalSampleRate;
          final historyBitrate = isLossyOutput ? finalBitrateKbps : null;

          await persistBeforePublishingDownloadCompletion(
            persist: () async {
              if (!settings.saveDownloadHistory) return;
              await ref
                  .read(downloadHistoryProvider.notifier)
                  .addToHistory(
                    _historyItemFromResult(
                      item: item,
                      trackToDownload: trackToDownload,
                      result: result,
                      filePath: historyFilePath,
                      quality: actualQuality,
                      useSaf: effectiveSafMode,
                      downloadTreeUri: settings.downloadTreeUri,
                      safRelativeDir: effectiveOutputDir,
                      safFileName: finalSafFileName ?? safFileName,
                      bitDepth: historyBitDepth,
                      sampleRate: historySampleRate,
                      bitrate: historyBitrate,
                      format: finalFormat,
                      genre: effectiveGenre,
                      label: effectiveLabel,
                      copyright: effectiveCopyright,
                    ),
                    preserveTrackVariant: item.preserveQualityVariant,
                  );
            },
            publish: () {
              _completedInSession++;
              updateItemStatus(
                item.id,
                DownloadStatus.completed,
                progress: 1.0,
                filePath: filePath,
              );
            },
          );
          await _notificationService.showDownloadComplete(
            trackName: item.track.name,
            artistName: item.track.artistName,
            completedCount: _completedInSession,
            totalCount: _totalQueuedAtStart,
            alreadyInLibrary: wasExisting,
          );
          removeItem(item.id);
        }
      } else {
        if (await shouldAbortWork('after backend failure')) {
          return;
        }

        var errorMsg = result['error'] as String? ?? 'Download failed';
        final errorTypeStr = result['error_type'] as String? ?? 'unknown';
        final retryAfterSeconds = readPositiveInt(
          result['retry_after_seconds'],
        );
        if (retryAfterSeconds != null && retryAfterSeconds > 0) {
          errorMsg = '$errorMsg retry-after: $retryAfterSeconds';
        }
        if (errorTypeStr == 'cancelled') {
          if (_isPausePending(item.id)) {
            pausedDuringThisRun = true;
            _requeueItemForPause(item.id);
            _log.i('Download was paused by backend cancellation, re-queueing');
          } else {
            _log.i(
              'Download was cancelled by backend, skipping error handling',
            );
            updateItemStatus(item.id, DownloadStatus.skipped);
          }
          return;
        }

        final backendErrorType = _downloadErrorTypeFromBackend(errorTypeStr);
        final errorType = backendErrorType == DownloadErrorType.unknown
            ? _downloadErrorTypeFromMessage(errorMsg)
            : backendErrorType;

        if (errorType == DownloadErrorType.verificationRequired) {
          await _handleVerificationRequiredDownload(
            item,
            errorMsg,
            result['service'] as String?,
          );
          return;
        }
        if (errorType == DownloadErrorType.rateLimit &&
            await _handleRateLimitedDownload(item, errorMsg)) {
          return;
        }

        _log.e('Download failed: $errorMsg (type: $errorTypeStr)');
        updateItemStatus(
          item.id,
          DownloadStatus.failed,
          error: errorMsg,
          errorType: errorType,
        );
        _failedInSession++;

        try {
          await PlatformBridge.cleanupConnections();
        } catch (e) {
          _log.e('Post-failure connection cleanup failed: $e');
        }
      }

      _downloadCount++;
      if (_downloadCount % DownloadQueueNotifier._cleanupInterval == 0) {
        _log.d(
          'Cleaning up idle connections (after $_downloadCount downloads)...',
        );
        try {
          await PlatformBridge.cleanupConnections();
        } catch (e) {
          _log.e('Connection cleanup failed: $e');
        }
      }
    } catch (e, stackTrace) {
      if (await shouldAbortWork('after exception')) {
        return;
      }

      _log.e('Exception: $e', e, stackTrace);

      String errorMsg = e.toString();
      DownloadErrorType errorType = DownloadErrorType.unknown;

      if (errorMsg.contains('could not find Deezer equivalent') ||
          errorMsg.contains('track not found on Deezer')) {
        errorMsg = 'Track not found on Deezer (Metadata Unavailable)';
        errorType = DownloadErrorType.notFound;
      } else {
        errorType = _downloadErrorTypeFromMessage(errorMsg);
      }

      if (errorType == DownloadErrorType.verificationRequired) {
        await _handleVerificationRequiredDownload(item, errorMsg, item.service);
        return;
      }
      if (errorType == DownloadErrorType.rateLimit &&
          await _handleRateLimitedDownload(item, errorMsg)) {
        return;
      }

      updateItemStatus(
        item.id,
        DownloadStatus.failed,
        error: errorMsg,
        errorType: errorType,
      );
      _failedInSession++;

      try {
        await PlatformBridge.cleanupConnections();
      } catch (cleanupErr) {
        _log.e('Post-exception connection cleanup failed: $cleanupErr');
      }
    } finally {
      if (pausedDuringThisRun) {
        _pausePendingItemIds.remove(item.id);
      }
    }
  }
}
