import 'package:flutter/widgets.dart';

/// Gives glass shaders the actual window's coordinate system.
///
/// AdaptiveUiScaler changes MediaQuery's size and density for layout and image
/// decoding. The glass renderer already includes that ancestor transform when
/// positioning its shader, so using the scaled density again displaces the
/// effect from its clip (especially near the bottom of a tablet screen).
class NativeGlassMetrics extends StatelessWidget {
  const NativeGlassMetrics({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final view = View.of(context);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: view.physicalSize / view.devicePixelRatio,
        devicePixelRatio: view.devicePixelRatio,
      ),
      child: child,
    );
  }
}
