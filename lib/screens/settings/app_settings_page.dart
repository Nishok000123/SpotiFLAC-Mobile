import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/backup_restore_service.dart';
import 'package:spotiflac_android/services/m3u_export_service.dart';
import 'package:spotiflac_android/utils/app_bar_layout.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final topPadding = normalizedHeaderTopPadding(context);

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 120 + topPadding,
              collapsedHeight: kToolbarHeight,
              floating: false,
              pinned: true,
              backgroundColor: colorScheme.surface,
              surfaceTintColor: Colors.transparent,
              leading: IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
              flexibleSpace: LayoutBuilder(
                builder: (context, constraints) {
                  final maxHeight = 120 + topPadding;
                  final minHeight = kToolbarHeight + topPadding;
                  final expandRatio =
                      ((constraints.maxHeight - minHeight) /
                              (maxHeight - minHeight))
                          .clamp(0.0, 1.0);
                  final leftPadding = 56 - (32 * expandRatio);
                  return FlexibleSpaceBar(
                    expandedTitleScale: 1.0,
                    titlePadding: EdgeInsets.only(
                      left: leftPadding,
                      bottom: 16,
                    ),
                    title: Text(
                      context.l10n.settingsApp,
                      style: TextStyle(
                        fontSize: 20 + (8 * expandRatio),
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionApp),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.extension,
                    title: context.l10n.optionsExtensionStore,
                    subtitle: context.l10n.optionsExtensionStoreSubtitle,
                    value: settings.showExtensionStore,
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .setShowExtensionStore(v),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.system_update,
                    title: context.l10n.optionsCheckUpdates,
                    subtitle: context.l10n.optionsCheckUpdatesSubtitle,
                    value: settings.checkForUpdates,
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .setCheckForUpdates(v),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.vibration,
                    title: 'Haptic Feedback',
                    subtitle: settings.hapticFeedback
                        ? 'Vibrate on download complete'
                        : 'No vibration',
                    value: settings.hapticFeedback,
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .setHapticFeedback(v),
                    showDivider: settings.checkForUpdates,
                  ),
                  if (settings.checkForUpdates)
                    _UpdateChannelSelector(
                      currentChannel: settings.updateChannel,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setUpdateChannel(v),
                    ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: 'Backup & Restore'),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.backup_outlined,
                    title: 'Backup Settings',
                    subtitle: 'Export all settings to a JSON file',
                    onTap: () => _backupSettings(context, ref),
                  ),
                  SettingsItem(
                    icon: Icons.restore_outlined,
                    title: 'Restore Settings',
                    subtitle: 'Import settings from a backup file',
                    onTap: () => _restoreSettings(context, ref, colorScheme),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionData),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.cleaning_services_outlined,
                    title: context.l10n.cleanupOrphanedDownloads,
                    subtitle: context.l10n.cleanupOrphanedDownloadsSubtitle,
                    onTap: () => _cleanupOrphanedDownloads(context, ref),
                  ),
                  SettingsItem(
                    icon: Icons.playlist_add_check_outlined,
                    title: 'Export Library as M3U Playlist',
                    subtitle: 'Save all downloaded tracks as a .m3u file',
                    onTap: () => _exportM3u(context, ref),
                  ),
                  SettingsItem(
                    icon: Icons.delete_forever,
                    title: context.l10n.optionsClearHistory,
                    subtitle: context.l10n.optionsClearHistorySubtitle,
                    onTap: () =>
                        _showClearHistoryDialog(context, ref, colorScheme),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionDebug),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.bug_report,
                    title: context.l10n.optionsDetailedLogging,
                    subtitle: settings.enableLogging
                        ? context.l10n.optionsDetailedLoggingOn
                        : context.l10n.optionsDetailedLoggingOff,
                    value: settings.enableLogging,
                    onChanged: (v) =>
                        ref.read(settingsProvider.notifier).setEnableLogging(v),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Future<void> _backupSettings(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final success = await BackupRestoreService.exportSettings(settings);
    if (!success && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Backup failed')));
    }
  }

  Future<void> _restoreSettings(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Settings?'),
        content: const Text(
          'This will overwrite your current settings. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.dialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Confirm', style: TextStyle(color: colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final imported = await BackupRestoreService.importSettings();
    if (imported == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to restore settings')),
        );
      }
      return;
    }

    ref.read(settingsProvider.notifier).restoreFromBackup(imported);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings restored successfully')),
      );
    }
  }

  Future<void> _exportM3u(BuildContext context, WidgetRef ref) async {
    final history = ref.read(downloadHistoryProvider).items;
    if (history.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No downloaded tracks to export')),
        );
      }
      return;
    }
    final success = await M3uExportService.exportAndShare(history);
    if (!success && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Export failed')));
    }
  }

  void _showClearHistoryDialog(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.dialogClearHistoryTitle),
        content: Text(context.l10n.dialogClearHistoryMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          TextButton(
            onPressed: () {
              ref.read(downloadHistoryProvider.notifier).clearHistory();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.snackbarHistoryCleared)),
              );
            },
            child: Text(
              context.l10n.dialogClear,
              style: TextStyle(color: colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _cleanupOrphanedDownloads(
    BuildContext context,
    WidgetRef ref,
  ) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Text(context.l10n.cleanupOrphanedDownloads),
          ],
        ),
      ),
    );
    try {
      final removed = await ref
          .read(downloadHistoryProvider.notifier)
          .cleanupOrphanedDownloads();
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              removed > 0
                  ? context.l10n.cleanupOrphanedDownloadsResult(removed)
                  : context.l10n.cleanupOrphanedDownloadsNone,
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.snackbarError(e.toString()))),
        );
      }
    }
  }
}

class _UpdateChannelSelector extends StatelessWidget {
  final String currentChannel;
  final ValueChanged<String> onChanged;
  const _UpdateChannelSelector({
    required this.currentChannel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.new_releases,
                color: colorScheme.onSurfaceVariant,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.optionsUpdateChannel,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentChannel == 'preview'
                          ? context.l10n.optionsUpdateChannelPreview
                          : context.l10n.optionsUpdateChannelStable,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _ChannelChip(
                label: context.l10n.channelStable,
                isSelected: currentChannel == 'stable',
                onTap: () => onChanged('stable'),
              ),
              const SizedBox(width: 8),
              _ChannelChip(
                label: context.l10n.channelPreview,
                isSelected: currentChannel == 'preview',
                onTap: () => onChanged('preview'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.optionsUpdateChannelWarning,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  const _ChannelChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.05),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHigh;
    return Expanded(
      child: Material(
        color: isSelected ? colorScheme.primaryContainer : unselectedColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
