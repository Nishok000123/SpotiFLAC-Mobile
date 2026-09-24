import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

/// Landscape opens on the player. Lyrics can hide their bottom actions until
/// the user touches the player, while the cover and header stay in place.
class MornyeLandscapePlayer extends StatefulWidget {
  const MornyeLandscapePlayer({
    super.key,
    required this.artwork,
    required this.header,
    required this.lyrics,
    required this.queue,
    required this.controls,
    required this.volume,
    required this.page,
    required this.onPageChanged,
  });

  final Widget artwork;
  final Widget header;
  final Widget lyrics;
  final Widget queue;
  final Widget controls;
  final Widget volume;
  final int page;
  final ValueChanged<int> onPageChanged;

  @override
  State<MornyeLandscapePlayer> createState() => _MornyeLandscapePlayerState();
}

class _MornyeLandscapePlayerState extends State<MornyeLandscapePlayer> {
  Timer? _hideTimer;
  bool _actionsVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.accessibleNavigationOf(context)) {
      _actionsVisible = true;
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  @override
  void didUpdateWidget(MornyeLandscapePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      _actionsVisible = true;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (widget.page != 1 ||
        !_actionsVisible ||
        MediaQuery.accessibleNavigationOf(context)) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduleHide();
        return;
      }
      setState(() => _actionsVisible = false);
    });
  }

  void _reveal() {
    if (!_actionsVisible) setState(() => _actionsVisible = true);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      _hideTimer?.cancel();
      if (!_actionsVisible) setState(() => _actionsVisible = true);
    },
    onPointerUp: (_) => _scheduleHide(),
    onPointerCancel: (_) => _scheduleHide(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Row(
        children: [
          Expanded(child: widget.artwork),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: widget.header,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          layoutBuilder: (current, previous) => Stack(
                            fit: StackFit.expand,
                            children: [
                              for (final child in previous)
                                IgnorePointer(
                                  child: ExcludeSemantics(child: child),
                                ),
                              ?current,
                            ],
                          ),
                          child: widget.page == 0
                              ? SingleChildScrollView(
                                  key: const ValueKey('landscape-controls'),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: constraints.maxHeight,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        widget.controls,
                                        widget.volume,
                                        const SizedBox(height: 48),
                                      ],
                                    ),
                                  ),
                                )
                              : Padding(
                                  key: ValueKey(widget.page),
                                  padding: EdgeInsets.only(
                                    bottom: widget.page == 2 ? 48 : 0,
                                  ),
                                  child: widget.page == 2
                                      ? widget.queue
                                      : widget.lyrics,
                                ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 48,
                          child: GestureDetector(
                            key: const ValueKey('landscape-actions-reveal'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _reveal,
                            child: IgnorePointer(
                              ignoring: !_actionsVisible,
                              child: ExcludeSemantics(
                                excluding: !_actionsVisible,
                                child: AnimatedOpacity(
                                  opacity: _actionsVisible ? 1 : 0,
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        IconButton(
                                          tooltip: widget.page == 1
                                              ? context.l10n.nowPlayingTabPlayer
                                              : context
                                                    .l10n
                                                    .nowPlayingTabLyrics,
                                          isSelected: widget.page == 1,
                                          icon: const Icon(
                                            CupertinoIcons.quote_bubble,
                                          ),
                                          onPressed: () => widget.onPageChanged(
                                            widget.page == 1 ? 0 : 1,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip:
                                              context.l10n.nowPlayingUpNext,
                                          icon: const Icon(
                                            CupertinoIcons.list_bullet,
                                          ),
                                          isSelected: widget.page == 2,
                                          onPressed: () => widget.onPageChanged(
                                            widget.page == 2 ? 0 : 2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
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
        ],
      ),
    ),
  );
}
