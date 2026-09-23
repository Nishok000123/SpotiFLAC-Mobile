import 'dart:async';

import 'package:flutter/material.dart';

/// Reveals overflowing content without making the mini player's text draggable.
class OverflowMarquee extends StatefulWidget {
  const OverflowMarquee({
    super.key,
    required this.resetKey,
    required this.child,
  });

  final Object resetKey;
  final Widget child;

  @override
  State<OverflowMarquee> createState() => _OverflowMarqueeState();
}

class _OverflowMarqueeState extends State<OverflowMarquee>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  Timer? _pause;
  int _generation = 0;
  bool _restartQueued = false;
  bool _motionEnabled = false;
  bool _appActive = true;
  double? _viewport;
  double? _extent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _queueRestart();
  }

  @override
  void didUpdateWidget(OverflowMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetKey != oldWidget.resetKey) {
      _queueRestart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _queueRestart();
  }

  void _queueRestart() {
    _pause?.cancel();
    _generation++;
    if (_restartQueued) return;
    _restartQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restartQueued = false;
      if (!mounted || !_scroll.hasClients) return;
      // Also cancels an in-flight animation after a track/width change.
      _scroll.jumpTo(0);
      if (_motionEnabled &&
          _appActive &&
          _scroll.position.maxScrollExtent > 0) {
        _scheduleLeg(towardEnd: true, generation: _generation);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _canScroll(int generation) =>
      mounted &&
      generation == _generation &&
      _motionEnabled &&
      _appActive &&
      _scroll.hasClients;

  void _scheduleLeg({required bool towardEnd, required int generation}) {
    _pause = Timer(
      Duration(milliseconds: towardEnd ? 1500 : 1200),
      () => _scrollLeg(towardEnd: towardEnd, generation: generation),
    );
  }

  Future<void> _scrollLeg({
    required bool towardEnd,
    required int generation,
  }) async {
    if (!_canScroll(generation)) return;
    final target = towardEnd ? _scroll.position.maxScrollExtent : 0.0;
    final distance = (target - _scroll.offset).abs();
    if (distance < 0.5) return;
    await _scroll.animateTo(
      target,
      duration: Duration(milliseconds: (distance / 28 * 1000).round()),
      curve: Curves.linear,
    );
    if (_canScroll(generation)) {
      _scheduleLeg(towardEnd: !towardEnd, generation: generation);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_motionEnabled) return widget.child;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (_viewport != metrics.viewportDimension ||
            _extent != metrics.maxScrollExtent) {
          _viewport = metrics.viewportDimension;
          _extent = metrics.maxScrollExtent;
          _queueRestart();
        }
        return false;
      },
      child: RepaintBoundary(
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: widget.child,
        ),
      ),
    );
  }
}
