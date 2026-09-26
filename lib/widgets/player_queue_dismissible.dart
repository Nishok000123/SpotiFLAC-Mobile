import 'package:flutter/material.dart';

/// Removing a row affects the queue only, never the song on disk.
class PlayerQueueDismissible extends StatelessWidget {
  const PlayerQueueDismissible({
    super.key,
    required this.onRemove,
    required this.child,
    this.enabled = true,
  });

  final VoidCallback onRemove;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Dismissible(
    key: const ValueKey('queue-dismiss'),
    direction: enabled ? DismissDirection.endToStart : DismissDirection.none,
    // Remove before collapsing so a concurrently playing row is never left
    // dismissed in the tree. The service resolves the entry by identity.
    confirmDismiss: (_) async {
      onRemove();
      return false;
    },
    background: Container(
      alignment: AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.delete_outline,
        color: Theme.of(context).colorScheme.onError,
        semanticLabel: MaterialLocalizations.of(context).deleteButtonTooltip,
      ),
    ),
    child: child,
  );
}
