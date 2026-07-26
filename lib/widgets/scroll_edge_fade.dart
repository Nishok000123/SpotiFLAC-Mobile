import 'package:flutter/material.dart';

/// Overlays a bottom gradient on a vertical scrollable while more content
/// remains below, signalling that the view can scroll.
class ScrollEdgeFade extends StatefulWidget {
  final Widget child;
  final double height;

  const ScrollEdgeFade({super.key, required this.child, this.height = 96});

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _hasMore = false;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis == Axis.vertical) {
      final hasMore = metrics.extentAfter > 8;
      if (hasMore != _hasMore) setState(() => _hasMore = hasMore);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) => _onMetrics(notification.metrics),
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (notification) => _onMetrics(notification.metrics),
            child: widget.child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _hasMore ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [background.withValues(alpha: 0), background],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
