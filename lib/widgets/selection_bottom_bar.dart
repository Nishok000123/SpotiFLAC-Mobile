import 'package:flutter/material.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

/// Mounts a selection bar in the **root** overlay.
///
/// The bar has to float above the shell's navigation bar, which lives outside
/// the per-tab navigators, so an in-tree `Positioned` inside the screen is not
/// enough. Five screens each solved this differently (two hand-rolled
/// `OverlayEntry` blocks, two `AnimatedPositioned` stacks and one bespoke
/// `Positioned` container); they now all go through this controller, which also
/// guarantees the same entrance animation everywhere.
class SelectionOverlayController {
  OverlayEntry? _entry;
  WidgetBuilder? _builder;

  bool get isVisible => _entry != null;

  /// Shows the bar, or rebuilds it in place when already visible so the
  /// entrance animation does not replay on every selection change.
  void show(BuildContext context, WidgetBuilder builder) {
    _builder = builder;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: AnimatedSelectionBottomBar(
          child: Material(
            color: Colors.transparent,
            child: _builder!(overlayContext),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void hide() {
    _entry?.remove();
    _entry = null;
    _builder = null;
  }

  /// Call from the host `State.dispose`; an entry left in the root overlay
  /// outlives the screen that created it.
  void dispose() => hide();
}

/// Entrance animation shared by selection bars mounted in the root overlay.
class AnimatedSelectionBottomBar extends StatefulWidget {
  const AnimatedSelectionBottomBar({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedSelectionBottomBar> createState() =>
      _AnimatedSelectionBottomBarState();
}

class _AnimatedSelectionBottomBarState extends State<AnimatedSelectionBottomBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(curve);
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(curve);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

/// Shared chrome for the multi-select bottom bar: rounded surface, drag
/// handle, close button, "N selected" header and select-all toggle.
/// The screen-specific action buttons go in [children].
class SelectionBottomBar extends StatelessWidget {
  const SelectionBottomBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.bottomPadding,
    required this.children,
    this.allSelectedLabel,
    this.tapToSelectLabel,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final double bottomPadding;
  final List<Widget> children;

  /// Overrides the default "All tracks selected" subtitle.
  final String? allSelectedLabel;

  /// Overrides the default "Tap tracks to select" subtitle.
  final String? tapToSelectLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.radiusSheet),
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding > 0 ? 8 : 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppSheetHandle(),

              Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: onClose,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(width: 12),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.selectionSelected(selectedCount),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          allSelected
                              ? allSelectedLabel ??
                                    context.l10n.selectionAllSelected
                              : tapToSelectLabel ??
                                    context.l10n.downloadedAlbumTapToSelect,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),

                  TextButton.icon(
                    onPressed: onToggleSelectAll,
                    icon: Icon(
                      allSelected ? Icons.deselect : Icons.select_all,
                      size: 20,
                    ),
                    label: Text(
                      allSelected
                          ? context.l10n.actionDeselect
                          : context.l10n.actionSelectAll,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.primary,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
