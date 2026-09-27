import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:spotiflac_android/theme/material_expressive.dart';

/// Indeterminate loading only. Downloads/analysis keep their real progress.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 32,
    this.color,
    this.semanticLabel,
  });

  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: materialExpressiveEnabled(context)
        ? MaterialExpressiveScope(
            child: FittedBox(
              child: M3ELoadingIndicator(
                size: 48,
                color: color,
                semanticLabel: semanticLabel,
              ),
            ),
          )
        : CircularProgressIndicator(
            color: color,
            strokeWidth: 3,
            semanticsLabel: semanticLabel,
          ),
  );
}
