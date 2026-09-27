import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:spotiflac_android/theme/material_expressive.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

/// A single tonal selection inside a sheet, without a second glass layer.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.visualDensity,
    this.singleChoice = false,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final VisualDensity? visualDensity;
  final bool singleChoice;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context) && label is Text) {
      final text = label as Text;
      return MaterialExpressiveScope(
        child: M3EChip(
          label: text.data ?? text.textSpan?.toPlainText() ?? '',
          type: M3EChipType.filter,
          selected: selected,
          onPressed: onSelected == null ? null : () => onSelected!(!selected),
        ),
      );
    }
    if (!context.isMornye) {
      if (singleChoice) {
        return ChoiceChip(
          label: label,
          selected: selected,
          onSelected: onSelected,
          visualDensity: visualDensity,
        );
      }
      return FilterChip(
        label: label,
        selected: selected,
        onSelected: onSelected,
        visualDensity: visualDensity,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final foreground = onSelected == null
        ? scheme.onSurfaceVariant
        : selected
        ? scheme.primary
        : scheme.onSurface;
    return Semantics(
      selected: selected,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        borderRadius: BorderRadius.circular(24),
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : MornyeTheme.controlFill(context),
        disabledColor: MornyeTheme.controlFill(context, enabled: false),
        onPressed: onSelected == null ? null : () => onSelected!(!selected),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
            color: foreground,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(CupertinoIcons.check_mark, size: 18, color: foreground),
                const SizedBox(width: 8),
              ],
              Flexible(child: label),
            ],
          ),
        ),
      ),
    );
  }
}
