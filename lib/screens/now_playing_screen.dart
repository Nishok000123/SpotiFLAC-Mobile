import 'dart:async';
import 'dart:ui' show BoxHeightStyle, ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/screens/downloaded_album_screen.dart';
import 'package:spotiflac_android/screens/local_album_screen.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/utils/clickable_metadata.dart';
import 'package:spotiflac_android/utils/file_access.dart';
import 'package:spotiflac_android/utils/int_utils.dart';
import 'package:spotiflac_android/utils/isrc_utils.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/string_utils.dart';
import 'package:spotiflac_android/utils/synced_lyrics_scroll.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/widgets/audio_quality_badges.dart';
import 'package:spotiflac_android/widgets/audio_output_button.dart';
import 'package:spotiflac_android/widgets/player_artwork.dart';
import 'package:spotiflac_android/widgets/overflow_marquee.dart';
import 'package:spotiflac_android/widgets/playback_seek_slider.dart';
import 'package:spotiflac_android/widgets/playlist_picker_sheet.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';
import 'package:spotiflac_android/widgets/mornye_volume_control.dart';
import 'package:spotiflac_android/widgets/mornye_player_queue.dart';
import 'package:spotiflac_android/widgets/mornye_player_background.dart';
import 'package:spotiflac_android/widgets/mornye_artwork_contrast.dart';
import 'package:spotiflac_android/widgets/mornye_playback_button.dart';
import 'package:spotiflac_android/widgets/mornye_playback_time.dart';
import 'package:spotiflac_android/widgets/mornye_player_actions_sheet.dart';
import 'package:spotiflac_android/widgets/mornye_context_menu.dart';
import 'package:spotiflac_android/widgets/mornye_landscape_player.dart';
import 'package:spotiflac_android/widgets/mornye_player_artwork.dart';
import 'package:spotiflac_android/providers/player_motion_artwork_provider.dart';
import 'package:spotiflac_android/widgets/mornye_player_details_sheet.dart';
import 'package:spotiflac_android/widgets/mornye_player_favorite_button.dart';

final _log = AppLogger('NowPlaying');

/// Hero tag shared by the mini player artwork and the full player artwork so
/// the cover visually expands when the player opens.
const kNowPlayingArtworkHeroTag = 'now-playing-artwork';

const _mornyeLyricFontSize = 34.0;
const _mornyeLyricFocusAlignment = 0.22;

/// Slide-up route for the full player. Supports live drag-to-dismiss: the
/// page follows the finger (via [startDrag]/[updateDrag]/[endDrag]) and
/// settles open or pops based on release position and velocity.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({this.miniPlayerGeometry}) : super(fullscreenDialog: true);

  /// Read at dismissal so rotation and collapsing navigation cannot leave a
  /// stale destination from when the player was opened.
  final ({Rect surface, Rect artwork})? Function()? miniPlayerGeometry;
  ({Rect bounds, Widget child, bool fullBleed})? Function()? _readArtwork;
  ({Rect surface, Rect artwork})? _dismissTarget;
  ({Rect bounds, Widget child, bool fullBleed})? _dismissArtwork;
  Rect? _dismissStart;
  double _dismissStartValue = 1;

  bool _interactiveTransition = false;
  int _dragGeneration = 0;

  // Keep the previous page painted where a drag exposes it. The player itself
  // fills the screen, including the status bar and bottom safe area.
  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  void startDrag() {
    _dragGeneration++;
    controller?.stop();
    if (!_interactiveTransition && controller != null) {
      controller!.value = Easing.emphasizedDecelerate.transform(
        controller!.value,
      );
    }
    _interactiveTransition = true;
    changedInternalState();
  }

  void updateDrag(DragUpdateDetails details, double pageHeight) {
    controller?.value -= (details.primaryDelta ?? 0) / pageHeight;
  }

  void endDrag(DragEndDetails details, double pageHeight) {
    final velocity = (details.primaryVelocity ?? 0) / pageHeight;
    final value = controller?.value ?? 1.0;
    if (velocity > 1.0 || (velocity >= 0 && value < 0.7)) {
      navigator?.pop();
    } else {
      _settleOpen();
    }
  }

  void cancelDrag() {
    _settleOpen();
  }

  void _settleOpen() {
    final generation = _dragGeneration;
    // Keep the same linear position mapping until settling finishes. Switching
    // to the entrance curve on release jumps away from the finger's position.
    controller
        ?.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (generation != _dragGeneration || !isCurrent) return;
          _interactiveTransition = false;
          changedInternalState();
        });
  }

  @override
  bool didPop(void result) {
    final context = subtreeContext;
    if (context != null &&
        context.isMornye &&
        !MediaQuery.disableAnimationsOf(context) &&
        (controller?.value ?? 0) > 0) {
      final target = miniPlayerGeometry?.call();
      if (target != null && !target.surface.isEmpty) {
        final size = MediaQuery.sizeOf(context);
        _dismissStartValue = controller!.value;
        final position = _interactiveTransition
            ? _dismissStartValue
            : Easing.emphasizedDecelerate.transform(_dismissStartValue);
        _dismissStart = Rect.fromLTWH(
          0,
          size.height * (1 - position),
          size.width,
          size.height,
        );
        _dismissTarget = target;
        _dismissArtwork = _readArtwork?.call();
      }
    }
    return super.didPop(result);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _RouteDragRegion(route: this, child: const NowPlayingScreen());
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final target = _dismissTarget;
    if (target != null) {
      final progress = Curves.easeInOutCubic.transform(
        (1 - animation.value / _dismissStartValue).clamp(0.0, 1.0),
      );
      final bounds = Rect.lerp(_dismissStart, target.surface, progress)!;
      final size = MediaQuery.sizeOf(context);
      final cover = _dismissArtwork;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(
            rect: bounds,
            child: ClipRRect(
              key: const ValueKey('player-minimize-surface'),
              borderRadius: BorderRadius.circular(28 * progress),
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: Transform.scale(
                  scale: bounds.width / size.width,
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: 1 - const Interval(0.15, 0.85).transform(progress),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
          if (cover != null)
            Positioned.fromRect(
              rect: Rect.lerp(cover.bounds, target.artwork, progress)!,
              child: ClipRRect(
                key: const ValueKey('player-minimize-artwork'),
                borderRadius: BorderRadius.circular(
                  cover.fullBleed ? 6 * progress : 12 - 6 * progress,
                ),
                child: cover.fullBleed
                    ? ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.58, 1],
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.white.withValues(alpha: progress),
                          ],
                        ).createShader(bounds),
                        child: cover.child,
                      )
                    : cover.child,
              ),
            ),
        ],
      );
    }
    final reversing = animation.status == AnimationStatus.reverse;
    // Mornye's full-bleed artwork travels with its panel. Material keeps the
    // independent cover flight back to the mini-player on button/back pop.
    final inPlacePop =
        reversing && !_interactiveTransition && !context.isMornye;
    final slide = _interactiveTransition
        ? animation
        : animation.drive(CurveTween(curve: Easing.emphasizedDecelerate));
    final position = inPlacePop
        ? const AlwaysStoppedAnimation(Offset.zero)
        : slide.drive(Tween(begin: const Offset(0, 1), end: Offset.zero));
    final opacity = inPlacePop ? animation : kAlwaysCompleteAnimation;
    return SlideTransition(
      position: position,
      child: FadeTransition(opacity: opacity, child: child),
    );
  }
}

/// Routes vertical drags to [NowPlayingRoute]. Scrollables inside [child]
/// still win the gesture arena, so this only fires on non-scrolling regions
/// (app bar, artwork, tab bar).
class _RouteDragRegion extends StatelessWidget {
  final NowPlayingRoute route;
  final Widget child;

  const _RouteDragRegion({required this.route, required this.child});

  @override
  Widget build(BuildContext context) {
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => route.startDrag(),
      onVerticalDragUpdate: (details) => route.updateDrag(details, pageHeight),
      onVerticalDragEnd: (details) => route.endDrag(details, pageHeight),
      onVerticalDragCancel: route.cancelDrag,
      child: child,
    );
  }
}

/// AppBar wrapper that fades with the route transition (see contentOpacity
/// in [_NowPlayingScreenState.build]).
class _FadingAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Animation<double> opacity;
  final AppBar child;

  const _FadingAppBar({required this.opacity, required this.child});

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: opacity, child: child);
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  final PageController _pageController = PageController();
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  String? _loadedSource;
  String? _loadedResolvedSource;
  String? _loadedMetadataPath;
  Map<String, dynamic>? _metadata;
  ParsedLyrics _lyrics = ParsedLyrics.empty;
  bool _loadingMeta = false;
  int _currentPage = 0;
  bool _landscape = false;
  bool _bottomDragForwarding = false;
  double _bottomDragTotal = 0;
  bool _queueSheetShowing = false;
  String? _measuredMotionSource;
  double? _motionAspectRatio;
  String? _failedMotionSource;
  bool _lyricsControlsHidden = false;
  bool _lyricsOptionsOpen = false;
  bool _audioOutputOpen = false;
  double _lyricsScrollDistance = 0;
  Timer? _lyricsIdleTimer;
  final _lyricsPointers = <int, Offset>{};
  bool _lyricsPointerMoved = false;
  final _artworkHeaderKey = GlobalKey();
  final _artworkControlsKey = GlobalKey();
  final _artworkVolumeKey = GlobalKey();
  final _expandedArtworkKey = GlobalKey();
  final _compactArtworkKey = GlobalKey();
  final _motionArtworkKey = GlobalKey();
  Map<String, Color> _artworkForeground = {};
  final _artworkColorsChanged = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) => _loadMetadataForItem(
        next.value,
        // When automatic playback advances while Lyrics is already visible,
        // onPageChanged will not run again. Inspect an unresolved SAF URI now
        // instead of leaving the new track with an empty Lyrics page.
        inspectUnresolvedContentUri: _currentPage == 1,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadMetadataForItem(ref.read(currentMediaItemProvider).value);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _landscape = context.isMornye && size.width > size.height;
    if (_landscape || MediaQuery.accessibleNavigationOf(context)) {
      _lyricsControlsHidden = false;
    }
    _scheduleLyricsControlsHide();
  }

  @override
  void dispose() {
    _lyricsIdleTimer?.cancel();
    _mediaItemSub?.close();
    _pageController.dispose();
    _artworkColorsChanged.dispose();
    super.dispose();
  }

  void _loadMetadataForItem(
    MediaItem? item, {
    bool inspectUnresolvedContentUri = false,
  }) {
    if (item == null) return;
    final source = item.extras?['source']?.toString() ?? '';
    if (source.isEmpty) return;
    final resolvedSource = item.extras?['resolvedSource']?.toString();
    unawaited(
      _loadMetadataFor(
        source,
        resolvedSource: resolvedSource,
        fallbackMetadata: playbackAudioMetadataFromMediaItem(item),
        inspectUnresolvedContentUri: inspectUnresolvedContentUri,
      ),
    );
  }

  Future<void> _loadMetadataFor(
    String source, {
    String? resolvedSource,
    Map<String, dynamic> fallbackMetadata = const {},
    bool inspectUnresolvedContentUri = false,
  }) async {
    final effectiveResolvedSource = resolvedSource?.trim();
    final path =
        (effectiveResolvedSource != null && effectiveResolvedSource.isNotEmpty)
        ? effectiveResolvedSource
        : source;
    final unresolvedContentUri =
        path == source && source.startsWith('content://');
    final sameItem =
        source == _loadedSource &&
        effectiveResolvedSource == _loadedResolvedSource;

    if (sameItem) {
      if (_metadata == null && fallbackMetadata.isNotEmpty) {
        setState(() => _metadata = fallbackMetadata);
      }
      if (_loadingMeta || _loadedMetadataPath == path) return;
      if (unresolvedContentUri && !inspectUnresolvedContentUri) return;
      setState(() => _loadingMeta = true);
    } else {
      _loadedSource = source;
      _loadedResolvedSource = effectiveResolvedSource;
      _loadedMetadataPath = null;
      setState(() {
        _loadingMeta = !unresolvedContentUri || inspectUnresolvedContentUri;
        _metadata = fallbackMetadata.isEmpty ? null : fallbackMetadata;
        _lyrics = ParsedLyrics.empty;
      });
    }

    // Avoid copying a restored SAF file merely because the player shell became
    // visible. If the user opens Lyrics before playback resolves a local temp
    // source, inspect the content URI on demand instead.
    if (unresolvedContentUri && !inspectUnresolvedContentUri) return;

    try {
      final meta = await readPlaybackFileMetadataWithRetry(path);
      if (!mounted ||
          _loadedSource != source ||
          _loadedResolvedSource != effectiveResolvedSource) {
        return;
      }
      setState(() {
        _loadedMetadataPath = path;
        _metadata = mergePlaybackFileMetadata(fallbackMetadata, meta);
        _lyrics = LyricsParser.parse((meta['lyrics'] ?? '').toString());
        _loadingMeta = false;
      });
    } catch (e) {
      _log.w('Failed to read metadata: $e');
      if (!mounted ||
          _loadedSource != source ||
          _loadedResolvedSource != effectiveResolvedSource) {
        return;
      }
      setState(() {
        _metadata = fallbackMetadata.isEmpty ? null : fallbackMetadata;
        _lyrics = ParsedLyrics.empty;
        _loadingMeta = false;
      });
    }
  }

  String? _qualityLabel() {
    final meta = _metadata;
    if (meta == null) return null;

    final parts = <String>[];
    final format = (meta['format'] ?? meta['audio_codec'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    if (format.isNotEmpty) parts.add(format);

    final bitDepth = readPositiveInt(meta['bit_depth']) ?? 0;
    if (bitDepth > 0) parts.add('$bitDepth-bit');

    final sampleRate = readPositiveInt(meta['sample_rate'])?.toDouble() ?? 0;
    if (sampleRate > 0) {
      final khz = sampleRate / 1000;
      final khzStr = khz == khz.roundToDouble()
          ? khz.toStringAsFixed(0)
          : khz.toStringAsFixed(1);
      parts.add('$khzStr kHz');
    }

    final bitrate = readPositiveInt(meta['bitrate']) ?? 0;
    if (bitDepth == 0 && bitrate > 0) parts.add('$bitrate kbps');

    if (parts.isEmpty) return null;
    return parts.join('  ·  ');
  }

  bool _isExplicit(MediaItem mediaItem) {
    final source = mediaItem.extras?['source']?.toString();
    final loadedMetadata = source == _loadedSource ? _metadata : null;
    return parseExplicitFlag(loadedMetadata?['explicit']) ??
        parseExplicitFlag(mediaItem.extras?['explicit']) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = mornye
        ? MornyeTheme.build(Brightness.dark).colorScheme
        : Theme.of(context).colorScheme;
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final controller = ref.read(musicPlayerControllerProvider);

    if (mediaItem == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: context.l10n.nowPlayingMinimize,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: Center(child: Text(context.l10n.nowPlayingNothingPlaying)),
      );
    }

    final source = mediaItem.extras?['source']?.toString() ?? '';
    final motionState = mornye && !MediaQuery.disableAnimationsOf(context)
        ? ref.watch(
            playerMotionArtworkProvider((
              album: mediaItem.album ?? '',
              artist: mediaItem.artist ?? '',
            )),
          )
        : null;
    final resolvedMotion = motionState?.value;
    final motionArtwork = resolvedMotion?.source == _failedMotionSource
        ? null
        : resolvedMotion;
    final motionRatio =
        motionArtwork?.aspectRatio ??
        (_measuredMotionSource == motionArtwork?.source
            ? _motionAspectRatio
            : null);
    final squareArtwork =
        motionArtwork == null || (motionRatio != null && motionRatio >= 0.95);
    if (motionArtwork == null) _artworkForeground = {};
    Widget artwork() => MornyePlayerArtwork(
      mediaItem: mediaItem,
      videoUrl: motionArtwork?.source,
      resolvingVideo: motionState?.isLoading == true,
      onAspectRatioChanged: (ratio) {
        if (!mounted ||
            (_measuredMotionSource == motionArtwork?.source &&
                _motionAspectRatio == ratio)) {
          return;
        }
        setState(() {
          _measuredMotionSource = motionArtwork?.source;
          _motionAspectRatio = ratio;
        });
      },
      onError: () {
        if (mounted) {
          setState(() => _failedMotionSource = motionArtwork?.source);
        }
      },
    );

    // The Mornye route moves the entire player together. A second,
    // delayed content fade would make dismissal appear to pause partway down.
    final route = ModalRoute.of(context);
    final routeAnimation = route?.animation ?? kAlwaysCompleteAnimation;
    if (mornye && route is NowPlayingRoute) {
      route._readArtwork = () {
        final key = _landscape
            ? _expandedArtworkKey
            : _currentPage != 0
            ? _compactArtworkKey
            : motionArtwork != null
            ? _motionArtworkKey
            : _expandedArtworkKey;
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return null;
        final overlay = route.navigator?.overlay?.context.findRenderObject();
        return (
          bounds: MatrixUtils.transformRect(
            box.getTransformTo(overlay),
            Offset.zero & box.size,
          ),
          fullBleed: key == _motionArtworkKey,
          child: Theme(
            data: MornyeTheme.build(Brightness.dark),
            child: key == _compactArtworkKey
                ? PlayerArtwork(
                    artUri: mediaItem.artUri?.toString(),
                    colorScheme: colorScheme,
                  )
                : artwork(),
          ),
        );
      };
    }
    final contentOpacity = mornye
        ? kAlwaysCompleteAnimation
        : routeAnimation.drive(
            CurveTween(curve: const Interval(0.4, 1.0, curve: Curves.easeOut)),
          );

    final player = Scaffold(
      backgroundColor: mornye ? Colors.transparent : colorScheme.surface,
      appBar: _FadingAppBar(
        opacity: contentOpacity,
        child: AppBar(
          backgroundColor: mornye ? Colors.transparent : colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: mornye ? SystemUiOverlayStyle.light : null,
          toolbarHeight: mornye
              ? (MediaQuery.orientationOf(context) == Orientation.landscape
                    ? 0
                    : 36)
              : kToolbarHeight,
          automaticallyImplyLeading: false,
          title: mornye
              ? MediaQuery.orientationOf(context) == Orientation.landscape
                    ? null
                    : IconButton(
                        tooltip: context.l10n.nowPlayingMinimize,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      )
              : Text(context.l10n.nowPlayingTitle),
          centerTitle: true,
          leading: mornye
              ? null
              : IconButton(
                  tooltip: context.l10n.nowPlayingMinimize,
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
          actions: mornye
              ? null
              : [
                  const AudioOutputButton(),
                  IconButton(
                    tooltip: context.l10n.nowPlayingUpNext,
                    icon: const Icon(Icons.queue_music),
                    onPressed: () => _showQueueSheet(colorScheme),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showMoreActions(
                      context: context,
                      mediaItem: mediaItem,
                      source: source,
                      colorScheme: colorScheme,
                    ),
                  ),
                ],
        ),
      ),
      body: FadeTransition(
        opacity: contentOpacity,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: mornye
                    ? _mornyePlayerPage(
                        mediaItem,
                        controller,
                        colorScheme,
                        motionArtwork: artwork(),
                        artworkAspectRatio: motionRatio,
                        insetArtwork: motionArtwork == null,
                      )
                    : PageView(
                        controller: _pageController,
                        onPageChanged: (page) {
                          if (_currentPage != page) {
                            setState(() => _currentPage = page);
                          }
                          if (page == 1) {
                            _loadMetadataForItem(
                              ref.read(currentMediaItemProvider).value,
                              inspectUnresolvedContentUri: true,
                            );
                          }
                        },
                        children: [
                          _playerPage(mediaItem, controller, colorScheme),
                          _lyricsSection(
                            colorScheme,
                            isActive: _currentPage == 1,
                          ),
                        ],
                      ),
              ),
              _autoHidingLyricsControls(
                _queueSwipeRegion(
                  colorScheme,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (mornye && !_landscape)
                        FractionallySizedBox(
                          widthFactor: 0.72,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                isSelected: _currentPage == 1,
                                color: Colors.white,
                                style: IconButton.styleFrom(
                                  backgroundColor: _currentPage == 1
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const Icon(CupertinoIcons.quote_bubble),
                                onPressed: _toggleMornyeLyrics,
                              ),
                              AudioOutputButton(
                                color: Colors.white,
                                onPickerChanged: (open) {
                                  if (!mounted) return;
                                  setState(() => _audioOutputOpen = open);
                                  _scheduleLyricsControlsHide();
                                },
                              ),
                              IconButton(
                                tooltip: context.l10n.nowPlayingUpNext,
                                color: Colors.white,
                                isSelected: _currentPage == 2,
                                style: IconButton.styleFrom(
                                  backgroundColor: _currentPage == 2
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const Icon(CupertinoIcons.list_bullet),
                                onPressed: () =>
                                    _setMornyePage(_currentPage == 2 ? 0 : 2),
                              ),
                            ],
                          ),
                        )
                      else if (!mornye)
                        _PageTabBar(
                          controller: _pageController,
                          colorScheme: colorScheme,
                          labels: [
                            context.l10n.nowPlayingTabPlayer,
                            context.l10n.nowPlayingTabLyrics,
                          ],
                        ),
                      if (!_landscape) const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mornye) return player;
    return HeroMode(
      // A route Hero renders outside the panel's gradient and slide, briefly
      // exposing a detached rectangle. Keep Mornye artwork inside its panel.
      enabled: false,
      child: Theme(
        data: MornyeTheme.build(Brightness.dark),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MornyeArtworkContrast(
              enabled:
                  motionArtwork != null && !_landscape && _currentPage == 0,
              targets: {
                'header': _artworkHeaderKey,
                'controls': _artworkControlsKey,
                'volume': _artworkVolumeKey,
              },
              onChanged: (colors) {
                if (!mounted) return;
                _artworkForeground = colors;
                _artworkColorsChanged.value++;
              },
              child: MornyePlayerBackground(
                artUri: mediaItem.artUri,
                squareArtwork: squareArtwork,
                artworkAspectRatio: motionRatio,
                artwork:
                    motionArtwork != null && !_landscape && _currentPage == 0
                    ? _transitionArtwork(
                        _motionArtworkKey,
                        Hero(tag: kNowPlayingArtworkHeroTag, child: artwork()),
                      )
                    : null,
              ),
            ),
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (!_canAutoHideLyricsControls) return;
                if (_lyricsPointers.isEmpty) _lyricsPointerMoved = false;
                _lyricsPointers[event.pointer] = event.position;
                _lyricsIdleTimer?.cancel();
              },
              onPointerMove: (event) {
                final origin = _lyricsPointers[event.pointer];
                if (origin != null && (event.position - origin).distance > 12) {
                  _lyricsPointerMoved = true;
                }
              },
              onPointerUp: (event) => _endLyricsInteraction(event.pointer),
              onPointerCancel: (event) =>
                  _endLyricsInteraction(event.pointer, cancelled: true),
              child: player,
            ),
          ],
        ),
      ),
    );
  }

  Widget _transitionArtwork(GlobalKey key, Widget child) {
    final route = ModalRoute.of(context);
    return AnimatedBuilder(
      animation: route?.animation ?? kAlwaysCompleteAnimation,
      child: child,
      builder: (_, child) => Opacity(
        key: key,
        opacity: route is NowPlayingRoute && route._dismissArtwork != null
            ? 0
            : 1,
        child: child,
      ),
    );
  }

  /// Swipe up (player content or bottom tab strip) opens the queue sheet; a
  /// downward drag is forwarded to the route's drag-to-dismiss instead.
  Widget _queueSwipeRegion(ColorScheme colorScheme, Widget child) {
    final route = ModalRoute.of(context);
    final npRoute = route is NowPlayingRoute ? route : null;
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) {
        _bottomDragForwarding = false;
        _bottomDragTotal = 0;
      },
      onVerticalDragUpdate: (details) {
        if (_bottomDragForwarding) {
          npRoute?.updateDrag(details, pageHeight);
          return;
        }
        _bottomDragTotal += details.primaryDelta ?? 0;
        if (_bottomDragTotal > 12 && npRoute != null) {
          npRoute.startDrag();
          _bottomDragForwarding = true;
        }
      },
      onVerticalDragEnd: (details) {
        if (_bottomDragForwarding) {
          npRoute?.endDrag(details, pageHeight);
        } else if ((details.primaryVelocity ?? 0) < -300 ||
            _bottomDragTotal < -40) {
          _showQueueSheet(colorScheme);
        }
      },
      onVerticalDragCancel: () {
        if (_bottomDragForwarding) npRoute?.cancelDrag();
      },
      child: child,
    );
  }

  /// The artwork sits inside a scroll view, which wins vertical drags from
  /// the route-level drag region — so the artwork hooks the route directly.
  Widget _artworkDragRegion(BuildContext context, Widget child) {
    final route = ModalRoute.of(context);
    if (route is! NowPlayingRoute) return child;
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => route.startDrag(),
      onVerticalDragUpdate: (details) => route.updateDrag(details, pageHeight),
      onVerticalDragEnd: (details) => route.endDrag(details, pageHeight),
      onVerticalDragCancel: route.cancelDrag,
      child: child,
    );
  }

  Widget _playerPage(
    MediaItem mediaItem,
    MusicPlayerController controller,
    ColorScheme colorScheme,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget artworkAt(double artSize) => Center(
          child: _artworkDragRegion(
            context,
            Hero(
              tag: kNowPlayingArtworkHeroTag,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: artSize,
                  height: artSize,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween(begin: 0.94, end: 1.0).animate(animation),
                        child: child,
                      ),
                    ),
                    child: PlayerArtwork(
                      key: ValueKey(
                        mediaItem.artUri?.toString() ?? mediaItem.id,
                      ),
                      artUri: mediaItem.artUri?.toString(),
                      colorScheme: colorScheme,
                      cacheWidth:
                          (artSize * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        // Tablet/landscape: artwork pane left, metadata and controls right,
        // instead of one narrow column in a sea of empty space.
        final twoPane =
            constraints.maxWidth >= 720 &&
            constraints.maxWidth > constraints.maxHeight;
        if (twoPane) {
          final artSize = (constraints.maxHeight - 96).clamp(0.0, 420.0);
          return Row(
            children: [
              Expanded(child: artworkAt(artSize)),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _metadataAndControls(
                        mediaItem,
                        controller,
                        colorScheme,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        final artSize = (constraints.maxWidth - 64).clamp(0.0, 360.0);
        // Not user-scrollable: a swipe up here opens the queue instead,
        // and a swipe down still dismisses the player via the route.
        return _queueSwipeRegion(
          colorScheme,
          SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 32,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  artworkAt(artSize),
                  const SizedBox(height: 32),
                  ..._metadataAndControls(mediaItem, controller, colorScheme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggleMornyeLyrics() {
    _setMornyePage(_currentPage == 1 ? 0 : 1);
  }

  void _setMornyePage(int page) {
    setState(() {
      _currentPage = page;
      _lyricsControlsHidden = false;
      _lyricsScrollDistance = 0;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      _loadMetadataForItem(
        ref.read(currentMediaItemProvider).value,
        inspectUnresolvedContentUri: true,
      );
    }
  }

  bool get _canAutoHideLyricsControls =>
      context.isMornye &&
      !_landscape &&
      _currentPage == 1 &&
      !MediaQuery.accessibleNavigationOf(context);

  void _scheduleLyricsControlsHide() {
    _lyricsIdleTimer?.cancel();
    if (!_canAutoHideLyricsControls ||
        _lyricsOptionsOpen ||
        _audioOutputOpen ||
        _lyricsControlsHidden ||
        _lyricsPointers.isNotEmpty) {
      return;
    }
    _lyricsIdleTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_canAutoHideLyricsControls) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduleLyricsControlsHide();
        return;
      }
      setState(() => _lyricsControlsHidden = true);
    });
  }

  void _endLyricsInteraction(int pointer, {bool cancelled = false}) {
    if (_lyricsPointers.remove(pointer) == null || _lyricsPointers.isNotEmpty) {
      return;
    }
    if (!cancelled && !_lyricsPointerMoved && _lyricsControlsHidden) {
      setState(() => _lyricsControlsHidden = false);
    }
    _scheduleLyricsControlsHide();
  }

  Widget _autoHidingLyricsControls(Widget child) {
    if (!context.isMornye) return child;
    final hidden = _currentPage == 1 && _lyricsControlsHidden && !_landscape;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    final content = ClipRect(
      child: Align(
        heightFactor: hidden ? 0 : 1,
        child: IgnorePointer(
          ignoring: hidden,
          child: ExcludeSemantics(
            excluding: hidden,
            child: AnimatedOpacity(
              opacity: hidden ? 0 : 1,
              duration: motion,
              child: child,
            ),
          ),
        ),
      ),
    );
    return motion == Duration.zero
        ? content
        : AnimatedSize(
            duration: motion,
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: content,
          );
  }

  Widget _mornyePlayerPage(
    MediaItem mediaItem,
    MusicPlayerController controller,
    ColorScheme colorScheme, {
    required Widget motionArtwork,
    double? artworkAspectRatio,
    required bool insetArtwork,
  }) {
    final showLyrics = _currentPage == 1;
    final showQueue = _currentPage == 2;
    final compactStage = showLyrics || showQueue;
    final artworkTopInset = MediaQuery.paddingOf(context).top + 36;
    ColorScheme foreground(String region) {
      final color = compactStage
          ? null
          : _artworkForeground[region] ?? colorScheme.onSurface;
      return color == null
          ? colorScheme
          : colorScheme.copyWith(
              onSurface: color,
              onSurfaceVariant: color.withValues(alpha: 0.72),
            );
    }

    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    Widget resize({
      required Widget child,
      AlignmentGeometry alignment = Alignment.center,
    }) => motion == Duration.zero
        ? child
        : AnimatedSize(
            duration: motion,
            curve: Curves.easeInOutCubic,
            alignment: alignment,
            child: child,
          );
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (!showLyrics ||
            _landscape ||
            notification.dragDetails == null ||
            notification.metrics.axis != Axis.vertical) {
          return false;
        }
        final delta = notification.scrollDelta ?? 0;
        if (delta.sign != _lyricsScrollDistance.sign) _lyricsScrollDistance = 0;
        _lyricsScrollDistance += delta;
        if (_lyricsScrollDistance.abs() >= 16) {
          final hidden = _lyricsScrollDistance > 0;
          if (hidden != _lyricsControlsHidden) {
            setState(() => _lyricsControlsHidden = hidden);
          }
          _lyricsScrollDistance = 0;
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = MediaQuery.sizeOf(context);
          final landscape = screenSize.width > screenSize.height;
          final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
          const compactCoverSize = 72.0;
          final compactHeaderHeight = (44 * scale + 4).clamp(
            compactCoverSize,
            double.infinity,
          );
          Widget stage({bool artworkOnly = false}) => LayoutBuilder(
            builder: (context, stage) {
              final compact = compactStage && !artworkOnly;
              final expandedArtwork =
                  artworkOnly || (!compactStage && insetArtwork);
              final artSize = (stage.maxWidth - (artworkOnly ? 56 : 48)).clamp(
                0.0,
                (stage.maxHeight - (artworkOnly ? 24 : 8)).clamp(0.0, 360.0),
              );
              final ratio = artworkAspectRatio ?? 1.0;
              final artWidth = ratio < 1 ? artSize * ratio : artSize;
              final artHeight = ratio > 1 ? artSize / ratio : artSize;
              final fullBleed = !insetArtwork && !artworkOnly;
              // Match the background's bounds even while this cover is hidden.
              // Opening/closing a panel then moves the cover between the same
              // two positions, with the playback controls painted above it.
              final motionHeight = artworkAspectRatio != null
                  ? (screenSize.width / ratio).clamp(
                      0.0,
                      screenSize.height * 0.75,
                    )
                  : screenSize.height * 0.66;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    top: 8 + compactHeaderHeight + 16,
                    child: IgnorePointer(
                      ignoring: !compact,
                      child: ExcludeSemantics(
                        excluding: !compact,
                        child: AnimatedSwitcher(
                          duration: motion,
                          switchInCurve: Curves.easeInOutCubic,
                          switchOutCurve: Curves.easeInOutCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 0.035),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                                fit: StackFit.expand,
                                children: [
                                  for (final child in previousChildren)
                                    IgnorePointer(
                                      child: ExcludeSemantics(child: child),
                                    ),
                                  ?currentChild,
                                ],
                              ),
                          // Keep the outgoing panel until it fades out;
                          // closing the queue must never substitute lyrics.
                          child: compact
                              ? KeyedSubtree(
                                  key: ValueKey(_currentPage),
                                  child: showQueue
                                      ? MornyePlayerQueue(
                                          colorScheme: colorScheme,
                                          onShuffleLibrary: () =>
                                              _shuffleLibrary(controller),
                                        )
                                      : _lyricsSection(
                                          colorScheme,
                                          isActive: showLyrics,
                                        ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: motion,
                    curve: Curves.easeInOutCubic,
                    top: !compact
                        ? fullBleed
                              ? -artworkTopInset
                              : (stage.maxHeight - artHeight) / 2
                        : 8,
                    left: !compact
                        ? fullBleed
                              ? 0
                              : (stage.maxWidth - artWidth) / 2
                        : 28,
                    width: !compact
                        ? fullBleed
                              ? stage.maxWidth
                              : artWidth
                        : compactCoverSize,
                    height: !compact
                        ? fullBleed
                              ? motionHeight
                              : artHeight
                        : compactCoverSize,
                    child: HeroMode(
                      enabled: expandedArtwork || compact,
                      child: AnimatedSwitcher(
                        duration: motion,
                        switchInCurve: Curves.easeInOutCubic,
                        switchOutCurve: Curves.easeInOutCubic,
                        layoutBuilder: (current, previous) => Stack(
                          fit: StackFit.expand,
                          children: [
                            for (final child in previous)
                              HeroMode(
                                enabled: false,
                                child: IgnorePointer(child: child),
                              ),
                            ?current,
                          ],
                        ),
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: !expandedArtwork && !compact
                            ? null
                            : KeyedSubtree(
                                key: ValueKey(
                                  expandedArtwork
                                      ? 'full-player-artwork'
                                      : 'compact-player-artwork',
                                ),
                                child: _artworkDragRegion(
                                  context,
                                  Hero(
                                    tag: kNowPlayingArtworkHeroTag,
                                    child: expandedArtwork
                                        ? Consumer(
                                            builder: (context, ref, child) =>
                                                AnimatedScale(
                                                  scale:
                                                      !insetArtwork ||
                                                          ref.watch(
                                                            playbackPlayingProvider,
                                                          )
                                                      ? 1
                                                      : 0.73,
                                                  duration: motion,
                                                  curve: Curves.easeInOutCubic,
                                                  child: child,
                                                ),
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Color(0x40000000),
                                                    blurRadius: 28,
                                                    offset: Offset(0, 16),
                                                  ),
                                                ],
                                              ),
                                              child: _transitionArtwork(
                                                _expandedArtworkKey,
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  child: motionArtwork,
                                                ),
                                              ),
                                            ),
                                          )
                                        : _transitionArtwork(
                                            _compactArtworkKey,
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: PlayerArtwork(
                                                artUri: mediaItem.artUri
                                                    ?.toString(),
                                                colorScheme: colorScheme,
                                                cacheWidth:
                                                    (360 *
                                                            MediaQuery.devicePixelRatioOf(
                                                              context,
                                                            ))
                                                        .round(),
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 28 + compactCoverSize + 12,
                    right: 28,
                    top: 8,
                    child: IgnorePointer(
                      ignoring: !compact,
                      child: ExcludeSemantics(
                        excluding: !compact,
                        child: AnimatedOpacity(
                          key: const ValueKey('compact-track-header'),
                          opacity: compact ? 1 : 0,
                          duration: motion,
                          // Pause the hidden marquee without freezing the
                          // header's own fade-out animation.
                          child: TickerMode(
                            enabled: compact,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: compactHeaderHeight,
                              ),
                              child: _trackHeader(
                                mediaItem,
                                colorScheme,
                                compact: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );

          // Portrait video must not push the metadata/transport below the
          // square-cover position. Leave room above the anchored volume row.
          final volumeGap = 8 + (constraints.maxHeight - 440).clamp(0.0, 24.0);
          // Keep transport close to the timeline; spare height belongs above
          // the volume row without moving either slider or the track header.
          final transportShift = landscape
              ? 0.0
              : ((volumeGap - 16) / 2).clamp(0.0, 8.0);
          Widget controls() => AnimatedBuilder(
            animation: _artworkColorsChanged,
            builder: (context, _) => _PlaybackControls(
              key: _artworkControlsKey,
              mediaId: mediaItem.id,
              duration: mediaItem.duration ?? Duration.zero,
              controller: controller,
              colorScheme: foreground('controls'),
              qualityLabel: _qualityLabel(),
              compact: landscape,
              transportTopPadding: 16 + transportShift,
            ),
          );

          if (landscape) {
            return MornyeLandscapePlayer(
              page: _currentPage,
              onPageChanged: _setMornyePage,
              artwork: stage(artworkOnly: true),
              header: _trackHeader(mediaItem, colorScheme, compact: true),
              lyrics: _lyricsSection(colorScheme, isActive: showLyrics),
              lyricsOptions: showLyrics
                  ? _lyricsOptionsButton(colorScheme)
                  : null,
              queue: MornyePlayerQueue(
                colorScheme: colorScheme,
                onShuffleLibrary: () => _shuffleLibrary(controller),
              ),
              controls: controls(),
              volume: const MornyeVolumeControl(),
            );
          }

          Widget content() => Column(
            children: [
              Expanded(child: stage()),
              resize(
                child: compactStage
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        key: _artworkHeaderKey,
                        padding: const EdgeInsets.fromLTRB(28, 12, 28, 8),
                        child: AnimatedBuilder(
                          animation: _artworkColorsChanged,
                          builder: (context, _) =>
                              _trackHeader(mediaItem, foreground('header')),
                        ),
                      ),
              ),
              _autoHidingLyricsControls(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    controls(),
                    SizedBox(height: volumeGap - transportShift),
                    AnimatedBuilder(
                      animation: _artworkColorsChanged,
                      builder: (context, _) => MornyeVolumeControl(
                        key: _artworkVolumeKey,
                        foreground: foreground('volume').onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          );

          // Controls keep their intrinsic height. Small portrait screens and
          // large accessibility text can scroll instead of clipping the volume.
          final minHeight =
              (showLyrics && _lyricsControlsHidden ? 250.0 : 480.0) +
              (scale - 1).clamp(0, 3) * 120;
          if (constraints.maxHeight < minHeight) {
            return SingleChildScrollView(
              child: SizedBox(height: minHeight, child: content()),
            );
          }
          return content();
        },
      ),
    );
  }

  Widget _trackHeader(
    MediaItem mediaItem,
    ColorScheme colorScheme, {
    bool compact = false,
  }) {
    return Builder(
      builder: (context) => Row(
        children: [
          Expanded(
            child: Builder(
              builder: (titleContext) => InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap:
                    (mediaItem.artist ?? '').trim().isEmpty &&
                        (mediaItem.album ?? '').trim().isEmpty
                    ? null
                    : () => _showTrackNavigationMenu(titleContext, mediaItem),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OverflowMarquee(
                      resetKey: (mediaItem.id, mediaItem.title),
                      child: ExplicitTrackTitle(
                        title: mediaItem.title,
                        explicit: _isExplicit(mediaItem),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 18 : 22,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    OverflowMarquee(
                      resetKey: (mediaItem.id, mediaItem.artist),
                      child: Text(
                        mediaItem.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 16 : 20,
                          color: colorScheme.onSurface.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          MornyePlayerFavoriteButton(
            key: ValueKey(mediaItem.id),
            mediaItem: mediaItem,
            compact: _currentPage != 0,
            color: colorScheme.onSurface,
          ),
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              color: colorScheme.onSurface,
              iconSize: _currentPage == 0 ? 24 : 28,
              icon: const Icon(CupertinoIcons.ellipsis),
              onPressed: () => _showMoreActions(
                context: context,
                mediaItem: mediaItem,
                source: mediaItem.extras?['source']?.toString() ?? '',
                colorScheme: colorScheme,
                anchor: mornyeMenuAnchor(buttonContext),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Title/artist, seek slider, and transport buttons — shared by the
  /// portrait column and the landscape right pane.
  List<Widget> _metadataAndControls(
    MediaItem mediaItem,
    MusicPlayerController controller,
    ColorScheme colorScheme,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.15),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Row(
            key: ValueKey(mediaItem.id),
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ExplicitTrackTitle(
                      title: mediaItem.title,
                      explicit: _isExplicit(mediaItem),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Consumer(
                      builder: (context, ref, _) {
                        final track = ref
                            .watch(playerCollectionTrackProvider(mediaItem))
                            .value;
                        return ClickableArtistName(
                          artistName: mediaItem.artist ?? '',
                          artistId: track?.artistId,
                          extensionId: track?.source,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      _PlaybackControls(
        key: ValueKey(mediaItem.id),
        mediaId: mediaItem.id,
        duration: mediaItem.duration ?? Duration.zero,
        controller: controller,
        colorScheme: colorScheme,
        qualityLabel: _qualityLabel(),
      ),
    ];
  }

  Widget _lyricsSection(ColorScheme colorScheme, {required bool isActive}) {
    if (_loadingMeta) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 40,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.nowPlayingNoLyrics,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (_lyrics.synced) {
      final visibility = ref.watch(
        settingsProvider.select(
          (settings) => (
            settings.playerShowPronunciation,
            settings.playerShowTranslation,
          ),
        ),
      );
      final options = isActive && !_landscape
          ? _lyricsOptionsButton(colorScheme)
          : null;
      return Stack(
        fit: StackFit.expand,
        children: [
          _SyncedLyricsView(
            lyrics: _lyrics,
            colorScheme: colorScheme,
            isActive: isActive,
            showPronunciation: visibility.$1,
            showTranslation: visibility.$2,
          ),
          if (options != null)
            Positioned(
              left: 24,
              bottom: 8,
              child: _autoHidingLyricsControls(options),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Text(
        _lyrics.plainText,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          height: 1.6,
          color: colorScheme.onSurface,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget? _lyricsOptionsButton(ColorScheme colorScheme) {
    if (_loadingMeta || !_lyrics.synced) return null;
    final pronunciation = _lyrics.lines.any(
      (line) => line.romanization?.trim().isNotEmpty == true,
    );
    final translation = _lyrics.lines.any(
      (line) => line.translation?.trim().isNotEmpty == true,
    );
    if (!pronunciation && !translation) return null;
    return Builder(
      builder: (buttonContext) => IconButton.filledTonal(
        key: const ValueKey('lyrics-language-options'),
        tooltip: context.l10n.nowPlayingLyricsLanguageOptions,
        icon: const Icon(Icons.translate_rounded),
        style: IconButton.styleFrom(
          foregroundColor: _lyricsOptionsOpen
              ? colorScheme.surface
              : colorScheme.onSurface,
          backgroundColor: colorScheme.onSurface.withValues(
            alpha: _lyricsOptionsOpen ? 0.85 : 0.16,
          ),
        ),
        onPressed: () => _showLyricsOptions(
          buttonContext,
          pronunciation: pronunciation,
          translation: translation,
        ),
      ),
    );
  }

  Future<void> _showLyricsOptions(
    BuildContext buttonContext, {
    required bool pronunciation,
    required bool translation,
  }) async {
    final settings = ref.read(settingsProvider);
    final l10n = context.l10n;
    final actions = <(String, String, IconData)>[
      if (pronunciation)
        (
          'pronunciation',
          settings.playerShowPronunciation
              ? l10n.nowPlayingHidePronunciation
              : l10n.nowPlayingShowPronunciation,
          settings.playerShowPronunciation
              ? Icons.voice_over_off_outlined
              : Icons.record_voice_over_outlined,
        ),
      if (translation)
        (
          'translation',
          settings.playerShowTranslation
              ? l10n.nowPlayingHideTranslation
              : l10n.nowPlayingShowTranslation,
          Icons.translate_rounded,
        ),
    ];
    _lyricsIdleTimer?.cancel();
    setState(() => _lyricsOptionsOpen = true);
    try {
      final anchor = mornyeMenuAnchor(buttonContext);
      final action = context.isMornye
          ? await showMornyeContextMenu<String>(
              context: buttonContext,
              anchor: anchor,
              preferAbove: true,
              builder: (menuContext) => MornyeContextMenu(
                dense: true,
                groups: [
                  [
                    for (final (value, label, icon) in actions)
                      MornyeMenuAction(
                        icon: icon,
                        label: label,
                        onPressed: () => Navigator.of(menuContext).pop(value),
                      ),
                  ],
                ],
              ),
            )
          : await showMenu<String>(
              context: buttonContext,
              position: RelativeRect.fromRect(
                anchor ?? Rect.zero,
                Offset.zero & MediaQuery.sizeOf(context),
              ),
              items: [
                for (final (value, label, icon) in actions)
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        Icon(icon),
                        const SizedBox(width: 12),
                        Flexible(child: Text(label)),
                      ],
                    ),
                  ),
              ],
            );
      if (!mounted) return;
      final notifier = ref.read(settingsProvider.notifier);
      if (action == 'pronunciation') {
        notifier.setPlayerShowPronunciation(!settings.playerShowPronunciation);
      } else if (action == 'translation') {
        notifier.setPlayerShowTranslation(!settings.playerShowTranslation);
      }
    } finally {
      if (mounted) {
        setState(() => _lyricsOptionsOpen = false);
        _scheduleLyricsControlsHide();
      }
    }
  }

  Future<void> _openExternally(String source) async {
    if (source.isEmpty) return;
    try {
      await openFile(source);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarCannotOpenFile(context.friendlyError(e)),
          ),
        ),
      );
    }
  }

  Future<void> _showTrackNavigationMenu(
    BuildContext titleContext,
    MediaItem mediaItem,
  ) async {
    final action = await showMornyeContextMenu<String>(
      context: titleContext,
      preferAbove: true,
      builder: (_) => MornyePlayerNavigationMenu(mediaItem: mediaItem),
    );
    if (!mounted) return;
    if (action == 'album') {
      await _goToCurrentAlbum(
        mediaItem: mediaItem,
        source: mediaItem.extras?['source']?.toString() ?? '',
      );
    } else if (action == 'artist') {
      await _goToCurrentArtist(mediaItem);
    }
  }

  Future<void> _goToCurrentArtist(MediaItem mediaItem) async {
    final track = ref.read(playerCollectionTrackProvider(mediaItem)).value;
    await navigateToArtist(
      context,
      artistName: mediaItem.artist ?? '',
      artistId: track?.artistId,
      extensionId: track?.source,
    );
  }

  Future<void> _updatePlayerCollection(
    MediaItem item, {
    required bool favorite,
  }) async {
    try {
      final provider = playerCollectionTrackProvider(item);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final track = await ref.read(provider.future);
      if (!mounted) return;
      if (favorite) {
        await ref.read(libraryCollectionsProvider.notifier).toggleLoved(track);
      } else {
        await showAddTrackToPlaylistSheet(context, ref, track);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    }
  }

  Future<void> _showMoreActions({
    required BuildContext context,
    required MediaItem mediaItem,
    required String source,
    required ColorScheme colorScheme,
    Rect? anchor,
  }) async {
    final controller = ref.read(musicPlayerControllerProvider);
    final sleepTimerEndsAt = controller.sleepTimerEndsAt;
    final sleepTimerSubtitle = sleepTimerEndsAt == null
        ? null
        : context.l10n.nowPlayingSleepTimerActive(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(sleepTimerEndsAt)),
          );
    final action = context.isMornye
        ? await showMornyeContextMenu<String>(
            context: context,
            anchor: anchor,
            preferAbove: true,
            builder: (_) => MornyePlayerActionsSheet(
              mediaItem: mediaItem,
              sleepTimerSubtitle: sleepTimerSubtitle,
            ),
          )
        : await showAppBottomSheet<String>(
            context: context,
            useRootNavigator: true,
            backgroundColor: colorScheme.surfaceContainerHigh,
            title: mediaItem.title,
            subtitle: mediaItem.artist,
            builder: (sheetContext) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SettingsGroup(
                children: [
                  if ((mediaItem.album ?? '').trim().isNotEmpty)
                    SettingsItem(
                      icon: Icons.album_outlined,
                      title: sheetContext.l10n.homeGoToAlbum,
                      onTap: () => Navigator.of(sheetContext).pop('album'),
                    ),
                  SettingsItem(
                    icon: Icons.info_outline,
                    title: sheetContext.l10n.nowPlayingDetails,
                    onTap: () => Navigator.of(sheetContext).pop('details'),
                  ),
                  SettingsItem(
                    icon: Icons.bedtime_outlined,
                    title: sheetContext.l10n.nowPlayingSleepTimer,
                    subtitle: sleepTimerSubtitle,
                    onTap: () => Navigator.of(sheetContext).pop('sleepTimer'),
                  ),
                  SettingsItem(
                    icon: Icons.open_in_new,
                    title: sheetContext.l10n.nowPlayingOpenInExternalPlayer,
                    trailing: Icon(
                      Icons.open_in_new,
                      size: 18,
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                    showDivider: false,
                    onTap: () => Navigator.of(sheetContext).pop('external'),
                  ),
                ],
              ),
            ),
          );
    if (!mounted || !context.mounted) return;
    switch (action) {
      case 'favorite':
        await _updatePlayerCollection(mediaItem, favorite: true);
        break;
      case 'playlist':
        await _updatePlayerCollection(mediaItem, favorite: false);
        break;
      case 'artist':
        await _goToCurrentArtist(mediaItem);
        break;
      case 'share':
        await SharePlus.instance.share(
          ShareParams(
            text: '${mediaItem.title} — ${mediaItem.artist ?? ''}',
            sharePositionOrigin:
                anchor ??
                Rect.fromCenter(
                  center: MediaQuery.sizeOf(context).center(Offset.zero),
                  width: 1,
                  height: 1,
                ),
          ),
        );
        break;
      case 'album':
        await _goToCurrentAlbum(mediaItem: mediaItem, source: source);
        break;
      case 'details':
        _showDetailsSheet(context, colorScheme);
        break;
      case 'sleepTimer':
        await _showSleepTimerSheet(context, controller, colorScheme);
        break;
      case 'external':
        await _openExternally(source);
        break;
    }
  }

  Future<void> _showSleepTimerSheet(
    BuildContext context,
    MusicPlayerController controller,
    ColorScheme colorScheme,
  ) async {
    const durations = [15, 30, 45, 60];
    final isActive = controller.sleepTimerEndsAt != null;
    final selection = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.nowPlayingSleepTimer,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SettingsGroup(
          children: [
            for (final minutes in durations)
              SettingsItem(
                icon: Icons.timer_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerMinutes(minutes),
                showDivider: isActive || minutes != durations.last,
                onTap: () => Navigator.of(sheetContext).pop('$minutes'),
              ),
            if (isActive)
              SettingsItem(
                icon: Icons.timer_off_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerOff,
                showDivider: false,
                onTap: () => Navigator.of(sheetContext).pop('off'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !context.mounted || selection == null) return;

    if (selection == 'off') {
      controller.cancelSleepTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.nowPlayingSleepTimerCancelled)),
      );
      return;
    }

    final minutes = int.tryParse(selection);
    if (minutes == null) return;
    controller.setSleepTimer(Duration(minutes: minutes));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.nowPlayingSleepTimerSet(
            context.l10n.nowPlayingSleepTimerMinutes(minutes),
          ),
        ),
      ),
    );
  }

  Future<void> _goToCurrentAlbum({
    required MediaItem mediaItem,
    required String source,
  }) async {
    final albumName = (mediaItem.album ?? '').trim();
    if (albumName.isEmpty) return;

    // Prefer the stored collection so this action remains useful offline and
    // opens the exact files the user is currently playing.
    try {
      final historyItem = source.isEmpty
          ? null
          : await ref
                .read(downloadHistoryProvider.notifier)
                .getByFilePathAsync(source);
      if (!mounted) return;
      if (historyItem != null) {
        final albumArtist = (historyItem.albumArtist ?? '').trim();
        pushViaPreferredNavigator(
          context,
          (_) => DownloadedAlbumScreen(
            albumName: historyItem.albumName,
            artistName: albumArtist.isNotEmpty
                ? albumArtist
                : historyItem.artistName,
            coverUrl: historyItem.coverUrl,
          ),
        );
        return;
      }
    } catch (e) {
      _log.w('Failed to resolve downloaded album: $e');
    }

    try {
      final row = await LibraryDatabase.instance.getById(mediaItem.id);
      if (!mounted) return;
      if (row != null) {
        final item = LocalLibraryItem.fromJson(row);
        final rows = await LibraryDatabase.instance
            .getQueueLocalAlbumTracksByKey(item.albumKey);
        if (!mounted) return;
        final tracks = rows
            .map(LocalLibraryItem.fromJson)
            .toList(growable: false);
        if (tracks.isNotEmpty) {
          final albumArtist = (item.albumArtist ?? '').trim();
          pushViaPreferredNavigator(
            context,
            (_) => LocalAlbumScreen(
              albumName: item.albumName,
              artistName: albumArtist.isNotEmpty
                  ? albumArtist
                  : item.artistName,
              coverPath: item.coverPath,
              tracks: tracks,
            ),
          );
          return;
        }
      }
    } catch (e) {
      _log.w('Failed to resolve local album: $e');
    }

    if (!mounted) return;
    await navigateToAlbum(
      context,
      albumName: albumName,
      artistName: mediaItem.artist,
      coverUrl: mediaItem.artUri?.toString(),
    );
  }

  Future<void> _shuffleLibrary(MusicPlayerController controller) async {
    try {
      final rows = await LibraryDatabase.instance.getAll();
      final media = rows
          .map(LocalLibraryItem.fromJson)
          .where((i) => i.filePath.trim().isNotEmpty)
          .map(playableFromLocal)
          .toList();
      if (media.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.nowPlayingLibraryEmpty)),
        );
        return;
      }
      media.shuffle();
      await controller.setShuffle(true);
      await controller.playAll(media);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.nowPlayingShuffleLibraryFailed(
              context.friendlyError(e),
            ),
          ),
        ),
      );
    }
  }

  void _showQueueSheet(ColorScheme colorScheme) {
    if (context.isMornye) {
      _setMornyePage(2);
      return;
    }
    if (_queueSheetShowing) return;
    _queueSheetShowing = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return Consumer(
              builder: (context, ref, _) {
                final queue = ref.watch(playQueueProvider).value ?? const [];
                final current = ref.watch(currentMediaItemProvider).value;
                final controller = ref.read(musicPlayerControllerProvider);
                final shuffleOn = ref.watch(
                  playbackStateProvider.select(
                    (s) => s.value?.shuffleMode == AudioServiceShuffleMode.all,
                  ),
                );
                final repeatMode = ref.watch(
                  playbackStateProvider.select(
                    (s) => s.value?.repeatMode ?? AudioServiceRepeatMode.none,
                  ),
                );
                final textTheme = Theme.of(context).textTheme;

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            context.l10n.nowPlayingUpNext,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: switch (repeatMode) {
                              AudioServiceRepeatMode.one =>
                                context.l10n.nowPlayingRepeatOne,
                              AudioServiceRepeatMode.none =>
                                context.l10n.nowPlayingRepeatOff,
                              _ => context.l10n.nowPlayingRepeatAll,
                            },
                            isSelected:
                                repeatMode != AudioServiceRepeatMode.none,
                            icon: Icon(
                              repeatMode == AudioServiceRepeatMode.one
                                  ? Icons.repeat_one
                                  : Icons.repeat,
                            ),
                            color: repeatMode != AudioServiceRepeatMode.none
                                ? colorScheme.primary
                                : null,
                            onPressed: () =>
                                controller.setRepeatMode(switch (repeatMode) {
                                  AudioServiceRepeatMode.none =>
                                    AudioServiceRepeatMode.all,
                                  AudioServiceRepeatMode.all =>
                                    AudioServiceRepeatMode.one,
                                  _ => AudioServiceRepeatMode.none,
                                }),
                          ),
                          IconButton(
                            tooltip: shuffleOn
                                ? context.l10n.nowPlayingShuffleOn
                                : context.l10n.nowPlayingPlayInOrder,
                            isSelected: shuffleOn,
                            icon: const Icon(Icons.shuffle),
                            color: shuffleOn ? colorScheme.primary : null,
                            onPressed: () => controller.setShuffle(!shuffleOn),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: () => _shuffleLibrary(controller),
                          icon: const Icon(Icons.shuffle, size: 18),
                          label: Text(context.l10n.nowPlayingShuffleLibrary),
                        ),
                      ),
                    ),
                    if (queue.isEmpty)
                      Expanded(
                        child: Center(
                          child: Text(
                            context.l10n.nowPlayingQueueEmpty,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: ReorderableListView.builder(
                          scrollController: scrollController,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                          itemCount: queue.length,
                          onReorderItem: (oldIndex, newIndex) {
                            controller.moveQueueItem(oldIndex, newIndex);
                          },
                          proxyDecorator: (child, index, animation) {
                            return Material(
                              elevation: 4,
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                              child: child,
                            );
                          },
                          itemBuilder: (context, i) {
                            final item = queue[i];
                            final isCurrent = current?.id == item.id;
                            return ListTile(
                              key: ValueKey('${item.id}_$i'),
                              contentPadding: const EdgeInsets.only(
                                left: 16,
                                right: 4,
                              ),
                              leading: Icon(
                                isCurrent ? Icons.equalizer : Icons.music_note,
                                color: isCurrent
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                              ),
                              title: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodyLarge?.copyWith(
                                  fontWeight: isCurrent
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isCurrent
                                      ? colorScheme.primary
                                      : colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                item.artist ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.drag_handle,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              onTap: () => controller.jumpTo(i),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    ).whenComplete(() => _queueSheetShowing = false);
  }

  void _showDetailsSheet(BuildContext context, ColorScheme colorScheme) {
    final mornye = context.isMornye;
    final mediaItem = ref.read(currentMediaItemProvider).value;
    final fallback = <String, dynamic>{
      if (mediaItem != null) ...{
        'title': mediaItem.title,
        'artist': mediaItem.artist ?? '',
        'album': mediaItem.album ?? '',
        ...playbackAudioMetadataFromMediaItem(mediaItem),
      },
      ...?_metadata,
    };
    final source = mediaItem?.extras?['source']?.toString() ?? '';
    final resolved = mediaItem?.extras?['resolvedSource']?.toString().trim();
    final path = resolved != null && resolved.isNotEmpty ? resolved : source;
    // Restored Android SAF items initially carry only queue metadata. Read
    // their tags on demand, even if playback has not resolved a local copy.
    final metadataFuture = path.isEmpty || _loadedMetadataPath == path
        ? Future.value(fallback)
        : readPlaybackFileMetadataWithRetry(path)
              .then((meta) => mergePlaybackFileMetadata(fallback, meta))
              .catchError((Object error) {
                _log.w('Failed to read details metadata: $error');
                return fallback;
              });
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: mornye,
      showDragHandle: !mornye,
      backgroundColor: mornye
          ? Colors.transparent
          : colorScheme.surfaceContainerHigh,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: mornye ? 0.75 : 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return FutureBuilder<Map<String, dynamic>>(
              future: metadataFuture,
              initialData: fallback,
              builder: (context, snapshot) => _MetadataList(
                meta: snapshot.data ?? fallback,
                colorScheme: colorScheme,
                scrollController: scrollController,
                mediaItem: mediaItem,
              ),
            );
          },
        );
      },
    );
  }
}

class _PlaybackControls extends ConsumerWidget {
  final String mediaId;
  final Duration duration;
  final MusicPlayerController controller;
  final ColorScheme colorScheme;
  final String? qualityLabel;
  final bool compact;
  final double transportTopPadding;

  const _PlaybackControls({
    super.key,
    required this.mediaId,
    required this.duration,
    required this.controller,
    required this.colorScheme,
    required this.qualityLabel,
    this.compact = false,
    this.transportTopPadding = 16,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mornye = context.isMornye;
    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final timeStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);
    final shuffleOn = ref.watch(
      playbackStateProvider.select(
        (s) => s.value?.shuffleMode == AudioServiceShuffleMode.all,
      ),
    );
    final repeatMode = ref.watch(
      playbackStateProvider.select(
        (s) => s.value?.repeatMode ?? AudioServiceRepeatMode.none,
      ),
    );
    return Column(
      children: [
        Consumer(
          builder: (context, ref, _) {
            final position = ref.watch(playbackPositionProvider);
            final elapsedSeconds = position.inSeconds;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: mornye ? 28 : 16),
              child: Column(
                children: [
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      activeTrackColor: mornye
                          ? colorScheme.onSurface
                          : colorScheme.primary,
                      inactiveTrackColor: colorScheme.onSurface.withValues(
                        alpha: 0.18,
                      ),
                      thumbColor: mornye
                          ? colorScheme.onSurface
                          : colorScheme.primary,
                      // A 7dp thumb was hard to grab; 10dp with a 24dp overlay
                      // gives the drag gesture a full-size target.
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 10,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 24,
                      ),
                    ),
                    child: PlaybackSeekSlider(
                      key: ValueKey(mediaId),
                      position: position,
                      duration: duration,
                      onSeek: controller.seek,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: mornye ? 8 : 12),
                    child: Row(
                      children: [
                        if (mornye)
                          MornyePlaybackTime(
                            key: ValueKey('elapsed:$mediaId'),
                            seconds: elapsedSeconds,
                            style: timeStyle,
                          )
                        else
                          Text(formatClock(elapsedSeconds), style: timeStyle),
                        Expanded(
                          child: Center(
                            child: _QualityBadge(
                              label: qualityLabel,
                              colorScheme: colorScheme,
                            ),
                          ),
                        ),
                        if (mornye)
                          MornyePlaybackTime(
                            key: ValueKey('remaining:$mediaId'),
                            // Subtract whole seconds so both labels roll together,
                            // even when the track duration includes milliseconds.
                            seconds: (duration.inSeconds - elapsedSeconds)
                                .clamp(0, duration.inSeconds),
                            remaining: true,
                            style: timeStyle,
                          )
                        else
                          Text(
                            formatClock(duration.inSeconds),
                            style: timeStyle,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        SizedBox(height: compact ? 8 : transportTopPadding),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: mornye ? (compact ? 16 : 32) : 0,
          ),
          child: Row(
            mainAxisAlignment: mornye
                ? MainAxisAlignment.spaceEvenly
                : MainAxisAlignment.center,
            children: [
              if (!mornye)
                IconButton(
                  iconSize: 24,
                  tooltip: shuffleOn
                      ? context.l10n.nowPlayingShuffleOn
                      : context.l10n.nowPlayingPlayInOrder,
                  color: shuffleOn
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.shuffle),
                  onPressed: () => controller.setShuffle(!shuffleOn),
                ),
              if (!mornye) const SizedBox(width: 8),
              if (mornye)
                MornyePlaybackButton(
                  icon: CupertinoIcons.backward_fill,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingPreviousTrack,
                  onPressed: controller.previous,
                )
              else
                IconButton(
                  iconSize: 44,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingPreviousTrack,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: controller.previous,
                ),
              if (!mornye) SizedBox(width: context.tokens.playerControlGap),
              if (mornye)
                MornyePlaybackButton(
                  icon: isPlaying
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  tooltip: isPlaying
                      ? context.l10n.actionPause
                      : context.l10n.tooltipPlay,
                  color: colorScheme.onSurface,
                  iconSize: compact ? 44 : 60,
                  // Keep the button's height stable as the glyph grows, so the
                  // timeline and artwork retain their existing positions.
                  padding: EdgeInsets.all(compact ? 12 : 4),
                  loading: isLoading,
                  onPressed: () => controller.togglePlayPause(isPlaying),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    iconSize: 44,
                    padding: const EdgeInsets.all(12),
                    color: colorScheme.onPrimary,
                    tooltip: isPlaying
                        ? context.l10n.actionPause
                        : context.l10n.tooltipPlay,
                    icon: isLoading
                        ? const SizedBox.square(
                            dimension: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: isLoading
                        ? null
                        : () => controller.togglePlayPause(isPlaying),
                  ),
                ),
              if (!mornye) SizedBox(width: context.tokens.playerControlGap),
              if (mornye)
                MornyePlaybackButton(
                  icon: CupertinoIcons.forward_fill,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingNextTrack,
                  onPressed: controller.next,
                )
              else
                IconButton(
                  iconSize: 44,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingNextTrack,
                  icon: const Icon(Icons.skip_next),
                  onPressed: controller.next,
                ),
              if (!mornye) const SizedBox(width: 8),
              if (!mornye)
                IconButton(
                  iconSize: 24,
                  tooltip: switch (repeatMode) {
                    AudioServiceRepeatMode.one =>
                      context.l10n.nowPlayingRepeatOne,
                    AudioServiceRepeatMode.none =>
                      context.l10n.nowPlayingRepeatOff,
                    _ => context.l10n.nowPlayingRepeatAll,
                  },
                  color: repeatMode == AudioServiceRepeatMode.none
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.primary,
                  icon: Icon(
                    repeatMode == AudioServiceRepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                  ),
                  onPressed: () => controller.setRepeatMode(
                    switch (repeatMode) {
                      AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                      AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                      _ => AudioServiceRepeatMode.none,
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SyncedLyricsView extends ConsumerStatefulWidget {
  final ParsedLyrics lyrics;
  final ColorScheme colorScheme;
  final bool isActive;
  final bool showPronunciation;
  final bool showTranslation;

  const _SyncedLyricsView({
    required this.lyrics,
    required this.colorScheme,
    required this.isActive,
    required this.showPronunciation,
    required this.showTranslation,
  });

  @override
  ConsumerState<_SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends ConsumerState<_SyncedLyricsView> {
  final ScrollController _scroll = ScrollController();
  ProviderSubscription<Duration>? _positionSubscription;
  ProviderSubscription<bool>? _playingSubscription;
  ProviderSubscription<bool>? _loadingSubscription;
  Timer? _lineBoundaryTimer;
  Timer? _userScrollIdleTimer;
  late List<GlobalKey> _lineKeys;
  int _active = -1;
  Duration _activeTransitionPosition = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _hasStarted = false;
  bool _userScrolling = false;
  static const double _estimatedLyricExtent = 64;
  List<double>? _lineExtents;
  List<(double, double, double)> _lineMeasurements = [];
  Object? _lineLayoutKey;
  double? _viewportHeight;
  Offset? _layoutVisibility;

  @override
  void initState() {
    super.initState();
    _resetLineKeys();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPositionSubscription();
  }

  @override
  void didUpdateWidget(covariant _SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _resetLineKeys();
    }
    if (oldWidget.isActive != widget.isActive ||
        oldWidget.lyrics != widget.lyrics) {
      _syncPositionSubscription();
    }
  }

  void _resetLineKeys() {
    _hasStarted = false;
    _lineExtents = null;
    _lineLayoutKey = null;
    _lineKeys = List<GlobalKey>.generate(
      widget.lyrics.lines.length,
      (index) => GlobalKey(debugLabel: 'lyric-line-$index'),
      growable: false,
    );
  }

  void _syncPositionSubscription() {
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _lineBoundaryTimer?.cancel();
    _positionSubscription = null;
    _playingSubscription = null;
    _loadingSubscription = null;
    if (!widget.isActive) return;
    _userScrollIdleTimer?.cancel();
    _userScrolling = false;

    final position = ref.read(playbackPositionProvider);
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    _active = _activeIndexAt(position);
    _activeTransitionPosition = position;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeAutoScroll(_active, immediate: true));
    });
    _scheduleNextLine(position);
    _positionSubscription = ref.listenManual<Duration>(
      playbackPositionProvider,
      (previous, next) {
        final active = _activeIndexAt(next);
        if (active != _active) _setActiveLine(active, position: next);
        _scheduleNextLine(next);
      },
    );
    _playingSubscription = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      next,
    ) {
      _playing = next;
      final position = ref.read(playbackPositionProvider);
      _setActiveLine(_activeIndexAt(position), position: position);
      _scheduleNextLine(position);
    });
    _loadingSubscription = ref.listenManual<bool>(playbackLoadingProvider, (
      previous,
      next,
    ) {
      _loading = next;
      final position = ref.read(playbackPositionProvider);
      _setActiveLine(_activeIndexAt(position), position: position);
      _scheduleNextLine(position);
    });
  }

  int _activeIndexAt(Duration position) {
    if (context.isMornye) {
      // Read one transport snapshot: playing/loading derived providers can
      // notify separately during the same playback event.
      final playback = ref.read(playbackStateProvider).value;
      if (playback?.processingState == AudioProcessingState.loading ||
          playback?.processingState == AudioProcessingState.buffering) {
        return -1;
      }
      _hasStarted =
          _hasStarted || playback?.playing == true || position > Duration.zero;
      if (!_hasStarted) return -1;
    }
    return LyricsParser.activeIndex(widget.lyrics.lines, position);
  }

  void _setActiveLine(int active, {required Duration position}) {
    if (!mounted || active == _active) return;
    setState(() {
      _active = active;
      _activeTransitionPosition = position;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeAutoScroll(active));
    });
  }

  void _scheduleNextLine(Duration position) {
    _lineBoundaryTimer?.cancel();
    if (!widget.isActive || !_playing || _loading) return;

    final lines = widget.lyrics.lines;
    final dueIndex = syncedLyricsDueLineIndex(
      lineStarts: lines.map((line) => line.time).toList(growable: false),
      currentIndex: _active,
      position: position,
    );
    if (dueIndex != _active) {
      _setActiveLine(dueIndex, position: position);
    }

    final nextIndex = dueIndex + 1;
    if (nextIndex >= lines.length) return;
    final boundary = lines[nextIndex].time;
    _lineBoundaryTimer = Timer(boundary - position, () {
      if (!mounted || !widget.isActive || !_playing || _loading) return;
      _scheduleNextLine(boundary);
    });
  }

  @override
  void dispose() {
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _lineBoundaryTimer?.cancel();
    _userScrollIdleTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _measureMornyeLines(double width) {
    final style = Theme.of(context).textTheme.headlineSmall?.copyWith(
      height: 1.3,
      fontSize: _mornyeLyricFontSize,
      fontWeight: FontWeight.bold,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final key = (width, style, scaler, direction, locale);
    if (_lineLayoutKey == key) return;
    _lineLayoutKey = key;
    final painter = TextPainter(
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    );
    final measurements = <(double, double, double)>[];
    for (final line in widget.lyrics.lines) {
      painter.text = TextSpan(
        text: line.text.trim().isEmpty ? '\u00b7\u00b7\u00b7' : line.text,
        style: style,
      );
      painter.layout(maxWidth: width);
      final height = painter.height + 32;
      var pronunciationHeight = 0.0;
      var translationHeight = 0.0;
      for (final (text, style, _, translation) in _lyricSupplements(
        context,
        line,
      )) {
        painter.text = TextSpan(text: text, style: style);
        painter.layout(maxWidth: width);
        if (translation) {
          translationHeight = 6 + painter.height;
        } else {
          pronunciationHeight = 6 + painter.height;
        }
      }
      measurements.add((height, pronunciationHeight, translationHeight));
    }
    _lineMeasurements = measurements;
    painter.dispose();
  }

  Future<void> _maybeAutoScroll(int index, {bool immediate = false}) async {
    if (_userScrolling || index < 0 || !_scroll.hasClients) return;
    final extents = _lineExtents;
    if (context.isMornye && extents != null && index < extents.length) {
      final position = _scroll.position;
      final padding = syncedLyricsCenterPadding(
        viewportDimension: position.viewportDimension,
        estimatedLineExtent: _estimatedLyricExtent,
      );
      final target =
          extents.take(index).fold(0.0, (sum, extent) => sum + extent) +
          padding -
          (position.viewportDimension - extents[index]).clamp(
                0.0,
                double.infinity,
              ) *
              _mornyeLyricFocusAlignment;
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (immediate || MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(offset);
      } else {
        await _scroll.animateTo(
          offset,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    if (index < _lineKeys.length) {
      final lineContext = _lineKeys[index].currentContext;
      if (lineContext != null) {
        await Scrollable.ensureVisible(
          lineContext,
          alignment: 0.5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          duration: immediate
              ? Duration.zero
              : const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
        return;
      }
    }

    final position = _scroll.position;
    final target = syncedLyricsEstimatedOffset(
      index: index,
      estimatedLineExtent: _estimatedLyricExtent,
    );
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scroll.animateTo(
      clamped.toDouble(),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || _userScrolling || index >= _lineKeys.length) return;
    final lineContext = _lineKeys[index].currentContext;
    if (lineContext != null && lineContext.mounted) {
      await Scrollable.ensureVisible(
        lineContext,
        alignment: 0.5,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Offset>(
    tween: Tween(
      end: Offset(
        widget.showPronunciation ? 1 : 0,
        widget.showTranslation ? 1 : 0,
      ),
    ),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320),
    curve: Curves.easeInOutCubic,
    builder: (context, visibility, _) => _buildLyrics(context, visibility),
  );

  Widget _buildLyrics(BuildContext context, Offset visibility) {
    final lines = widget.lyrics.lines;
    final active = _active;
    final mornye = context.isMornye;
    final highContrast = MediaQuery.highContrastOf(context);
    final blurLyrics =
        mornye &&
        !highContrast &&
        (!ref.watch(lowEndDeviceProvider) ||
            ref.watch(backdropBlurEnabledProvider));
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);

    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction != ScrollDirection.idle) {
          _userScrolling = true;
          _userScrollIdleTimer?.cancel();
          _userScrollIdleTimer = Timer(const Duration(seconds: 4), () {
            if (!mounted) return;
            _userScrolling = false;
            unawaited(_maybeAutoScroll(_active));
          });
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (mornye) {
            _measureMornyeLines(
              (constraints.maxWidth - 48).clamp(0, double.infinity),
            );
            // Reuse text measurements; only interpolate row heights as the
            // supplements fade. Scrolling follows the same animation clock.
            _lineExtents = [
              for (final (primary, pronunciation, translation)
                  in _lineMeasurements)
                primary +
                    pronunciation * visibility.dx +
                    translation * visibility.dy,
            ];
          }
          if (_viewportHeight != constraints.maxHeight ||
              _layoutVisibility != visibility) {
            _viewportHeight = constraints.maxHeight;
            _layoutVisibility = visibility;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                unawaited(_maybeAutoScroll(_active, immediate: true));
              }
            });
          }
          final centerPadding = syncedLyricsCenterPadding(
            viewportDimension: constraints.maxHeight,
            estimatedLineExtent: _estimatedLyricExtent,
          );
          // Leave enough trailing space for the final line to reach the same
          // upper focus position as every other line.
          final bottomPadding = mornye && _lineExtents!.isNotEmpty
              ? ((constraints.maxHeight - _lineExtents!.last) *
                        (1 - _mornyeLyricFocusAlignment))
                    .clamp(centerPadding, double.infinity)
              : centerPadding;
          return ListView.builder(
            controller: _scroll,
            itemExtentBuilder: mornye
                ? (index, _) => _lineExtents![index]
                : null,
            padding: EdgeInsets.fromLTRB(24, centerPadding, 24, bottomPadding),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == active;
              final isPast = index < active;

              final color = mornye
                  ? Colors.white
                  : isActive
                  ? widget.colorScheme.onSurface
                  : isPast
                  ? widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                  : widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.8);

              final text = line.text.trim().isEmpty
                  ? '\u00b7\u00b7\u00b7'
                  : line.text;

              final timed =
                  isActive &&
                  (line.hasWordTiming || line.romanizationWords.isNotEmpty);
              Widget content;
              if (timed) {
                content = _WordHighlightedLyricLine(
                  line: line,
                  colorScheme: widget.colorScheme,
                  animate: widget.isActive,
                  initialPosition: _activeTransitionPosition,
                  supplementVisibility: visibility,
                );
              } else {
                content = Text(
                  text,
                  textAlign: mornye ? TextAlign.start : TextAlign.center,
                  style:
                      (mornye || isActive
                              ? Theme.of(context).textTheme.headlineSmall
                              : Theme.of(context).textTheme.titleLarge)
                          ?.copyWith(
                            height: context.tokens.lyricsLineHeight,
                            fontSize: mornye ? _mornyeLyricFontSize : null,
                            fontWeight: mornye || isActive
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: color,
                          ),
                );
                content = _withLyricSupplements(
                  context,
                  line,
                  content,
                  color,
                  visibility: visibility,
                );
              }
              content = AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                reverseDuration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: KeyedSubtree(
                  key: ValueKey(timed),
                  child: mornye
                      ? SizedBox(width: double.infinity, child: content)
                      : content,
                ),
              );
              if (mornye) {
                final distance = (index - active).abs();
                // Nearby lines need visible defocus at the larger lyric size;
                // progressively soften lines further from the current one.
                final sigma = !blurLyrics || isActive
                    ? 0.0
                    : active < 0
                    ? 4.8
                    : distance == 1
                    ? 2.4
                    : distance == 2
                    ? 3.6
                    : 4.8;
                content = TweenAnimationBuilder<double>(
                  tween: Tween(end: sigma),
                  duration: motion,
                  child: RepaintBoundary(child: content),
                  builder: (context, value, child) => ImageFiltered(
                    enabled: value > 0,
                    imageFilter: ImageFilter.blur(sigmaX: value, sigmaY: value),
                    child: child,
                  ),
                );
              }

              return Padding(
                key: _lineKeys[index],
                padding: EdgeInsets.symmetric(
                  vertical: context.tokens.lyricsLinePaddingV,
                ),
                child: GestureDetector(
                  onTap: () =>
                      ref.read(musicPlayerControllerProvider).seek(line.time),
                  child: AnimatedScale(
                    scale: mornye || isActive ? 1.0 : 0.96,
                    alignment: Alignment.center,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: mornye
                          ? (isActive || highContrast ? 1 : 0.48)
                          : (isActive ? 1.0 : (isPast ? 0.55 : 0.85)),
                      duration: const Duration(milliseconds: 280),
                      child: content,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

Iterable<(String, TextStyle, List<LyricWord>, bool)> _lyricSupplements(
  BuildContext context,
  LyricLine line,
) sync* {
  final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
  for (final (text, translation) in [
    (line.romanization, false),
    (line.translation, true),
  ]) {
    if (text == null || text.trim().isEmpty) continue;
    yield (
      text,
      base.copyWith(
        fontSize: context.isMornye
            ? (translation ? 15 : 17)
            : (translation ? 14 : 16),
        height: 1.35,
        fontWeight: FontWeight.w500,
      ),
      translation ? const <LyricWord>[] : line.romanizationWords,
      translation,
    );
  }
}

Widget _withLyricSupplements(
  BuildContext context,
  LyricLine line,
  Widget primary,
  Color color, {
  required Offset visibility,
  Widget Function(String, List<LyricWord>, TextStyle)? timedText,
}) {
  if (line.romanization == null && line.translation == null) return primary;
  return Column(
    crossAxisAlignment: context.isMornye
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      primary,
      for (final (text, style, words, translation) in _lyricSupplements(
        context,
        line,
      ))
        if ((translation ? visibility.dy : visibility.dx) > 0)
          ClipRect(
            child: Align(
              alignment: context.isMornye
                  ? Alignment.topLeft
                  : Alignment.topCenter,
              heightFactor: translation ? visibility.dy : visibility.dx,
              child: Opacity(
                opacity: translation ? visibility.dy : visibility.dx,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: words.isNotEmpty && timedText != null
                      ? timedText(text, words, style)
                      : Text(
                          text,
                          textAlign: context.isMornye
                              ? TextAlign.start
                              : TextAlign.center,
                          style: style.copyWith(
                            color: color.withValues(alpha: color.a * 0.8),
                          ),
                        ),
                ),
              ),
            ),
          ),
    ],
  );
}

class _WordHighlightedLyricLine extends ConsumerStatefulWidget {
  final LyricLine line;
  final ColorScheme colorScheme;
  final bool animate;
  final Duration initialPosition;
  final Offset supplementVisibility;

  const _WordHighlightedLyricLine({
    required this.line,
    required this.colorScheme,
    required this.animate,
    required this.initialPosition,
    required this.supplementVisibility,
  });

  @override
  ConsumerState<_WordHighlightedLyricLine> createState() =>
      _WordHighlightedLyricLineState();
}

class _WordHighlightedLyricLineState
    extends ConsumerState<_WordHighlightedLyricLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationClock;
  final Stopwatch _elapsedClock = Stopwatch();
  ProviderSubscription<Duration>? _positionSubscription;
  ProviderSubscription<bool>? _playingSubscription;
  ProviderSubscription<bool>? _loadingSubscription;

  late Duration _anchorPosition;
  Duration _anchorElapsed = Duration.zero;
  bool _playing = false;
  bool _loading = false;

  bool get _shouldAnimate => widget.animate && _playing && !_loading;

  Duration _positionAt({required bool advance}) {
    return interpolatedSyncedLyricsPosition(
      anchorPosition: _anchorPosition,
      elapsedSinceAnchor: _elapsedClock.elapsed - _anchorElapsed,
      isPlaying: advance,
    );
  }

  @override
  void initState() {
    super.initState();
    _elapsedClock.start();
    _anchorElapsed = _elapsedClock.elapsed;
    _anchorPosition = widget.initialPosition;
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    _animationClock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _positionSubscription = ref.listenManual<Duration>(
      playbackPositionProvider,
      (previous, next) => _updateReportedPosition(next),
    );
    _playingSubscription = ref.listenManual<bool>(
      playbackPlayingProvider,
      (previous, next) => _updateTransportState(playing: next),
    );
    _loadingSubscription = ref.listenManual<bool>(
      playbackLoadingProvider,
      (previous, next) => _updateTransportState(loading: next),
    );
    _syncAnimationClock();
  }

  @override
  void didUpdateWidget(covariant _WordHighlightedLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line != widget.line ||
        oldWidget.initialPosition != widget.initialPosition) {
      _anchorAt(widget.initialPosition);
    }
    if (oldWidget.animate != widget.animate) {
      _anchorAt(
        _positionAt(advance: oldWidget.animate && _playing && !_loading),
      );
      _syncAnimationClock();
    }
  }

  Duration _currentPosition() {
    return _positionAt(advance: _shouldAnimate);
  }

  void _anchorAt(Duration position) {
    _anchorPosition = position;
    _anchorElapsed = _elapsedClock.elapsed;
  }

  void _updateReportedPosition(Duration position) {
    if (!mounted) return;
    final predicted = _currentPosition();
    _anchorAt(
      _shouldAnimate
          ? reconcileSyncedLyricsPosition(
              predictedPosition: predicted,
              reportedPosition: position,
            )
          : position,
    );
    setState(() {});
  }

  void _updateTransportState({bool? playing, bool? loading}) {
    if (!mounted) return;
    final position = _currentPosition();
    if (playing != null) _playing = playing;
    if (loading != null) _loading = loading;
    _anchorAt(_shouldAnimate ? position : ref.read(playbackPositionProvider));
    _syncAnimationClock();
    setState(() {});
  }

  void _syncAnimationClock() {
    if (_shouldAnimate) {
      if (!_animationClock.isAnimating) {
        _animationClock.repeat();
      }
    } else {
      _animationClock.stop();
    }
  }

  Duration _segmentEnd(List<LyricWord> words, int index) {
    final word = words[index];
    final start = word.time;
    if (word.end != null && word.end! >= start) return word.end!;
    if (index + 1 < words.length) {
      final next = words[index + 1].time;
      if (next > start) return next;
    }
    final lineEnd = widget.line.end;
    if (lineEnd != null && lineEnd > start) return lineEnd;
    return start + const Duration(milliseconds: 650);
  }

  @override
  void dispose() {
    _positionSubscription?.close();
    _playingSubscription?.close();
    _loadingSubscription?.close();
    _animationClock.dispose();
    _elapsedClock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildHighlightedLine(context);
  }

  Widget _buildHighlightedLine(BuildContext context) {
    final style =
        (Theme.of(context).textTheme.headlineSmall ?? const TextStyle())
            .copyWith(
              fontSize: context.isMornye ? _mornyeLyricFontSize : null,
              height: context.tokens.lyricsLineHeight,
              fontWeight: FontWeight.bold,
            );
    final primary = widget.line.hasWordTiming
        ? _buildTimedText(widget.line.text, widget.line.words, style)
        : Text(
            widget.line.text,
            textAlign: context.isMornye ? TextAlign.start : TextAlign.center,
            style: style.copyWith(color: widget.colorScheme.onSurface),
          );
    // Both scripts share this state's position interpolation and animation
    // clock, including pause, seek and track changes.
    return _withLyricSupplements(
      context,
      widget.line,
      primary,
      widget.colorScheme.onSurface,
      timedText: _buildTimedText,
      visibility: widget.supplementVisibility,
    );
  }

  Widget _buildTimedText(String text, List<LyricWord> words, TextStyle style) {
    final highlightedColor = widget.colorScheme.onSurface;
    final mornye = context.isMornye;
    final pendingColor = mornye
        ? Colors.white.withValues(alpha: 0.4)
        : widget.colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
    final segments = <String>[];
    final starts = <Duration>[];
    final ends = <Duration>[];
    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      segments.add(word.text);
      starts.add(word.time);
      ends.add(_segmentEnd(words, index));
    }

    return _SweepingTimedLyricText(
      segments: segments,
      starts: starts,
      ends: ends,
      currentPosition: _currentPosition,
      repaint: _animationClock,
      style: style,
      textAlign: mornye ? TextAlign.start : TextAlign.center,
      pendingColor: pendingColor,
      highlightedColor: highlightedColor,
      semanticsLabel: text,
    );
  }
}

class _SweepingTimedLyricText extends StatefulWidget {
  final List<String> segments;
  final List<Duration> starts;
  final List<Duration> ends;
  final Duration Function() currentPosition;
  final Listenable repaint;
  final TextStyle style;
  final TextAlign textAlign;
  final Color pendingColor;
  final Color highlightedColor;
  final String semanticsLabel;

  const _SweepingTimedLyricText({
    required this.segments,
    required this.starts,
    required this.ends,
    required this.currentPosition,
    required this.repaint,
    required this.style,
    required this.textAlign,
    required this.pendingColor,
    required this.highlightedColor,
    required this.semanticsLabel,
  });

  @override
  State<_SweepingTimedLyricText> createState() =>
      _SweepingTimedLyricTextState();
}

class _SweepingTimedLyricTextState extends State<_SweepingTimedLyricText> {
  TextPainter? _pendingPainter;
  TextPainter? _highlightedPainter;
  String? _cachedText;
  TextStyle? _cachedStyle;
  TextAlign? _cachedAlignment;
  TextDirection? _cachedDirection;
  TextScaler? _cachedScaler;
  Locale? _cachedLocale;
  Color? _cachedPendingColor;
  Color? _cachedHighlightedColor;

  void _ensurePainters(
    String text,
    TextDirection textDirection,
    TextScaler textScaler,
    Locale? locale,
  ) {
    if (_cachedText == text &&
        _cachedStyle == widget.style &&
        _cachedAlignment == widget.textAlign &&
        _cachedDirection == textDirection &&
        _cachedScaler == textScaler &&
        _cachedLocale == locale &&
        _cachedPendingColor == widget.pendingColor &&
        _cachedHighlightedColor == widget.highlightedColor) {
      return;
    }

    _pendingPainter?.dispose();
    _highlightedPainter?.dispose();
    _pendingPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: widget.style.copyWith(color: widget.pendingColor),
      ),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    );
    _highlightedPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: widget.style.copyWith(color: widget.highlightedColor),
      ),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    );
    _cachedText = text;
    _cachedStyle = widget.style;
    _cachedAlignment = widget.textAlign;
    _cachedDirection = textDirection;
    _cachedScaler = textScaler;
    _cachedLocale = locale;
    _cachedPendingColor = widget.pendingColor;
    _cachedHighlightedColor = widget.highlightedColor;
  }

  @override
  void dispose() {
    _pendingPainter?.dispose();
    _highlightedPainter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final text = widget.segments.join();
    _ensurePainters(text, textDirection, textScaler, locale);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final pendingPainter = _pendingPainter!
          ..layout(
            minWidth: constraints.hasBoundedWidth ? maxWidth : 0,
            maxWidth: maxWidth,
          );
        final highlightedPainter = _highlightedPainter!
          ..layout(
            minWidth: constraints.hasBoundedWidth ? maxWidth : 0,
            maxWidth: maxWidth,
          );
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : pendingPainter.width;
        final height = pendingPainter.height;
        final segmentBoxes = <List<Rect>>[];
        var segmentOffset = 0;
        for (final segment in widget.segments) {
          final segmentEnd = segmentOffset + segment.length;
          final boxes =
              highlightedPainter
                  .getBoxesForSelection(
                    TextSelection(
                      baseOffset: segmentOffset,
                      extentOffset: segmentEnd,
                    ),
                    boxHeightStyle: BoxHeightStyle.max,
                  )
                  .map((box) => box.toRect())
                  .toList()
                ..sort((a, b) {
                  final row = a.top.compareTo(b.top);
                  return row == 0 ? a.left.compareTo(b.left) : row;
                });
          segmentBoxes.add(boxes);
          segmentOffset = segmentEnd;
        }

        return Semantics(
          label: widget.semanticsLabel,
          child: CustomPaint(
            size: Size(width, height),
            painter: _TimedLyricSweepPainter(
              segmentBoxes: segmentBoxes,
              starts: widget.starts,
              ends: widget.ends,
              currentPosition: widget.currentPosition,
              repaint: widget.repaint,
              pendingPainter: pendingPainter,
              highlightedPainter: highlightedPainter,
            ),
          ),
        );
      },
    );
  }
}

class _TimedLyricSweepPainter extends CustomPainter {
  final List<List<Rect>> segmentBoxes;
  final List<Duration> starts;
  final List<Duration> ends;
  final Duration Function() currentPosition;
  final TextPainter pendingPainter;
  final TextPainter highlightedPainter;

  _TimedLyricSweepPainter({
    required this.segmentBoxes,
    required this.starts,
    required this.ends,
    required this.currentPosition,
    required Listenable repaint,
    required this.pendingPainter,
    required this.highlightedPainter,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    pendingPainter.paint(canvas, Offset.zero);

    final completedPath = Path();
    final partialBoxes = <(Rect, double)>[];
    final position = currentPosition();
    for (var index = 0; index < segmentBoxes.length; index++) {
      final value = index < starts.length && index < ends.length
          ? syncedLyricSegmentProgress(
              position: position,
              start: starts[index],
              end: ends[index],
            )
          : 0.0;
      if (value > 0) {
        final boxes = segmentBoxes[index];
        // Font fallback and wrapping can split one timed segment into several
        // boxes. Consume its progress once, instead of lighting every box at
        // the same time (which starts highlights in the middle of the text).
        var revealWidth =
            boxes.fold<double>(0, (width, box) => width + box.width) * value;
        for (final box in boxes) {
          if (revealWidth <= 0) break;
          if (box.width <= 0) continue;
          if (revealWidth >= box.width) {
            completedPath.addRect(box);
          } else {
            partialBoxes.add((box, revealWidth / box.width));
          }
          revealWidth -= box.width;
        }
      }
    }

    if (!completedPath.getBounds().isEmpty) {
      canvas.save();
      canvas.clipPath(completedPath);
      highlightedPainter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    for (final (box, value) in partialBoxes) {
      final boundary = syncedLyricsLeftToRightBoundary(
        left: box.left,
        right: box.right,
        progress: value,
      );
      final feather = (box.width * 0.18).clamp(3.0, 10.0);
      final revealRight = (boundary + feather).clamp(box.left, box.right);
      final revealRect = Rect.fromLTRB(
        box.left,
        box.top,
        revealRight,
        box.bottom,
      );
      final gradientStart = boundary.clamp(box.left, revealRight - 0.01);

      canvas.save();
      canvas.clipRect(revealRect);
      canvas.saveLayer(revealRect, Paint());
      highlightedPainter.paint(canvas, Offset.zero);
      final mask = Paint()
        ..blendMode = BlendMode.dstIn
        ..shader =
            LinearGradient(
              colors: const [Colors.white, Colors.transparent],
            ).createShader(
              Rect.fromLTRB(gradientStart, box.top, revealRight, box.bottom),
            );
      canvas.drawRect(revealRect, mask);
      canvas.restore();
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _TimedLyricSweepPainter oldDelegate) {
    return oldDelegate.segmentBoxes != segmentBoxes ||
        oldDelegate.starts != starts ||
        oldDelegate.ends != ends ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.pendingPainter != pendingPainter ||
        oldDelegate.highlightedPainter != highlightedPainter;
  }
}

class _MetadataList extends StatelessWidget {
  final Map<String, dynamic> meta;
  final ColorScheme colorScheme;
  final ScrollController scrollController;
  final MediaItem? mediaItem;

  const _MetadataList({
    required this.meta,
    required this.colorScheme,
    required this.scrollController,
    this.mediaItem,
  });

  @override
  Widget build(BuildContext context) {
    String s(Object? v) => (v ?? '').toString();
    final l10n = context.l10n;
    final rows = <(String, String)>[
      (l10n.editMetadataFieldTitle, s(meta['title'])),
      (l10n.editMetadataFieldArtist, s(meta['artist'])),
      (l10n.editMetadataFieldAlbum, s(meta['album'])),
      (l10n.editMetadataFieldAlbumArtist, s(meta['album_artist'])),
      (l10n.editMetadataFieldGenre, s(meta['genre'])),
      (l10n.editMetadataFieldComposer, s(meta['composer'])),
      (l10n.editMetadataFieldDate, s(meta['date'])),
      (l10n.editMetadataFieldTrackNum, s(meta['track_number'])),
      (l10n.editMetadataFieldDiscNum, s(meta['disc_number'])),
      (l10n.editMetadataFieldIsrc, formatIsrcForDisplay(s(meta['isrc']))),
      (l10n.editMetadataFieldLabel, s(meta['label'])),
      (l10n.editMetadataFieldCopyright, s(meta['copyright'])),
      (l10n.libraryFilterFormat, s(meta['format']).toUpperCase()),
      (l10n.audioAnalysisCodec, s(meta['audio_codec'])),
      (
        l10n.audioAnalysisSampleRate,
        meta['sample_rate'] != null && (meta['sample_rate'] as num? ?? 0) > 0
            ? '${((meta['sample_rate'] as num) / 1000).toStringAsFixed(1)} kHz'
            : '',
      ),
      (
        l10n.audioAnalysisBitDepth,
        (meta['bit_depth'] as num? ?? 0) > 0 ? '${meta['bit_depth']}-bit' : '',
      ),
    ].where((r) => r.$2.trim().isNotEmpty && r.$2 != '0').toList();

    if (context.isMornye) {
      return MornyePlayerDetailsSheet(
        rows: rows,
        scrollController: scrollController,
        mediaItem: mediaItem,
      );
    }

    final textTheme = Theme.of(context).textTheme;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Card(
          elevation: 0,
          color: settingsGroupColor(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.nowPlayingDetails,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ...rows.map(
                  (row) => Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 4,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 100,
                          child: Text(
                            row.$1,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.$2,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PageTabBar extends StatelessWidget {
  final PageController controller;
  final ColorScheme colorScheme;
  final List<String> labels;

  const _PageTabBar({
    required this.controller,
    required this.colorScheme,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        double page = 0;
        if (controller.hasClients && controller.position.haveDimensions) {
          page = controller.page ?? controller.initialPage.toDouble();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / labels.length;
            final indicatorWidth = (tabWidth * 0.5).clamp(28.0, 80.0);
            final base =
                Theme.of(context).textTheme.labelLarge ?? const TextStyle();

            return SizedBox(
              height: 38,
              child: Stack(
                children: [
                  Row(
                    children: List.generate(labels.length, (i) {
                      // Distance of this tab from the current page position,
                      // used to interpolate color/weight as the user swipes.
                      final t = (1.0 - (page - i).abs()).clamp(0.0, 1.0);
                      return Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => controller.animateToPage(
                            i,
                            duration: const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic,
                          ),
                          child: Center(
                            child: Text(
                              labels[i],
                              style: base.copyWith(
                                fontWeight: FontWeight.lerp(
                                  FontWeight.w500,
                                  FontWeight.bold,
                                  t,
                                ),
                                color: Color.lerp(
                                  colorScheme.onSurfaceVariant.withValues(
                                    alpha: 0.55,
                                  ),
                                  colorScheme.primary,
                                  t,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  // Sliding underline that tracks the swipe in real time.
                  Positioned(
                    bottom: 0,
                    left:
                        page.clamp(0, (labels.length - 1).toDouble()) *
                            tabWidth +
                        (tabWidth - indicatorWidth) / 2,
                    child: Container(
                      width: indicatorWidth,
                      height: 3,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final String? label;
  final ColorScheme colorScheme;

  const _QualityBadge({required this.label, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final text = label;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: context.isMornye
          ? null
          : BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 11, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
