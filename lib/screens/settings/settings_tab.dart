import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/screens/settings/about_page.dart';
import 'package:spotiflac_android/screens/settings/app_settings_page.dart';
import 'package:spotiflac_android/screens/settings/appearance_settings_page.dart';
import 'package:spotiflac_android/screens/settings/backup_restore_page.dart';
import 'package:spotiflac_android/screens/settings/cache_management_page.dart';
import 'package:spotiflac_android/screens/settings/donate_page.dart';
import 'package:spotiflac_android/screens/settings/download_settings_page.dart';
import 'package:spotiflac_android/screens/settings/extensions_page.dart';
import 'package:spotiflac_android/screens/settings/files_settings_page.dart';
import 'package:spotiflac_android/screens/settings/library_settings_page.dart';
import 'package:spotiflac_android/screens/settings/log_screen.dart';
import 'package:spotiflac_android/screens/settings/lyrics_settings_page.dart';
import 'package:spotiflac_android/screens/settings/metadata_settings_page.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/utils/adaptive_layout.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/animation_utils.dart';
import 'package:spotiflac_android/widgets/app_search_field.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// One entry on the Settings tab.
class _Destination {
  const _Destination({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
    this.keywords = const [],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget Function() pageBuilder;

  /// Extra search terms for things the title does not spell out (e.g. "SAF"
  /// for the Files page), so a user can find a page by what it does.
  final List<String> keywords;

  bool matches(String query) {
    if (query.isEmpty) return true;
    final haystack = [title, subtitle, ...keywords].join(' ').toLowerCase();
    return haystack.contains(query);
  }
}

/// Destinations that stay visually connected inside one settings card.
class _Group {
  const _Group({required this.destinations});

  final List<_Destination> destinations;
}

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Related destinations share one card; whitespace separates each group
  /// without adding section labels that compete with the page title.
  List<_Group> _groups(BuildContext context) {
    final l10n = context.l10n;
    return [
      _Group(
        destinations: [
          _Destination(
            icon: Icons.favorite_outline,
            title: l10n.settingsDonate,
            subtitle: l10n.settingsDonateSubtitle,
            keywords: const ['support', 'ko-fi', 'sponsor'],
            pageBuilder: () => const DonatePage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.extension_outlined,
            title: l10n.settingsExtensions,
            subtitle: l10n.settingsExtensionsSubtitle,
            keywords: const ['plugin', 'provider', 'priority', 'store'],
            pageBuilder: () => const ExtensionsPage(),
          ),
          _Destination(
            icon: Icons.palette_outlined,
            title: l10n.settingsAppearance,
            subtitle: l10n.settingsAppearanceSubtitle,
            keywords: const [
              'theme',
              'dark',
              'light',
              'amoled',
              'color',
              'language',
              'locale',
              'layout',
              'grid',
            ],
            pageBuilder: () => const AppearanceSettingsPage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.library_music_outlined,
            title: l10n.settingsLocalLibrary,
            subtitle: l10n.settingsLocalLibrarySubtitle,
            keywords: const [
              'scan',
              'local',
              'player',
              'playback',
              'duplicate',
            ],
            pageBuilder: () => const LibrarySettingsPage(),
          ),
          _Destination(
            icon: Icons.sell_outlined,
            title: l10n.settingsMetadata,
            subtitle: l10n.settingsMetadataSubtitle,
            keywords: const ['tag', 'cover', 'artwork', 'isrc', 'provider'],
            pageBuilder: () => const MetadataSettingsPage(),
          ),
          _Destination(
            icon: Icons.lyrics_outlined,
            title: l10n.settingsLyrics,
            subtitle: l10n.settingsLyricsSubtitle,
            keywords: const ['lrc', 'synced', 'provider'],
            pageBuilder: () => const LyricsSettingsPage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.download_outlined,
            title: l10n.settingsDownload,
            subtitle: l10n.settingsDownloadSubtitle,
            keywords: const [
              'quality',
              'flac',
              'concurrent',
              'network',
              'wifi',
              'service',
              'region',
            ],
            pageBuilder: () => const DownloadSettingsPage(),
          ),
          _Destination(
            icon: Icons.folder_outlined,
            title: l10n.settingsFiles,
            subtitle: l10n.settingsFilesSubtitle,
            keywords: const [
              'saf',
              'storage',
              'folder',
              'filename',
              'path',
              'permission',
            ],
            pageBuilder: () => const FilesSettingsPage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.tune_outlined,
            title: l10n.settingsApp,
            subtitle: l10n.settingsAppSubtitle,
            keywords: const ['update', 'channel', 'debug', 'logging'],
            pageBuilder: () => const AppSettingsPage(),
          ),
          _Destination(
            icon: Icons.storage_outlined,
            title: l10n.settingsCache,
            subtitle: l10n.settingsCacheSubtitle,
            keywords: const ['clear', 'space', 'image', 'temp'],
            pageBuilder: () => const CacheManagementPage(),
          ),
          _Destination(
            icon: Icons.settings_backup_restore,
            title: l10n.settingsBackup,
            subtitle: l10n.settingsBackupSubtitle,
            keywords: const ['export', 'import', 'restore', 'json'],
            pageBuilder: () => const BackupRestorePage(),
          ),
          _Destination(
            icon: Icons.article_outlined,
            title: l10n.logTitle,
            subtitle: l10n.settingsLogsSubtitle,
            keywords: const ['debug', 'error', 'report'],
            pageBuilder: () => const LogScreen(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.info_outline,
            title: l10n.settingsAbout,
            subtitle: '${l10n.aboutVersion} ${AppInfo.displayVersion}',
            keywords: const ['version', 'license', 'contributor'],
            pageBuilder: () => const AboutPage(),
          ),
        ],
      ),
    ];
  }

  void _navigateTo(BuildContext context, Widget page) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(slidePageRoute<void>(page: page));
  }

  Widget _itemFor(_Destination destination, {required bool showDivider}) {
    return SettingsItem(
      icon: destination.icon,
      title: destination.title,
      subtitle: destination.subtitle,
      showDivider: showDivider,
      onTap: () => _navigateTo(context, destination.pageBuilder()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final bottomInset = context.navBarBottomInset;
    final wideInset = wideListInset(context);
    final query = _query.trim().toLowerCase();
    final groups = _groups(context);

    final margin = EdgeInsets.fromLTRB(
      tokens.gapLg + wideInset,
      tokens.gapSm,
      tokens.gapLg + wideInset,
      tokens.gapSm,
    );

    final List<Widget> body;
    if (query.isEmpty) {
      body = [
        for (final group in groups)
          SliverToBoxAdapter(
            child: SettingsGroup(
              margin: margin,
              children: [
                for (var i = 0; i < group.destinations.length; i++)
                  _itemFor(
                    group.destinations[i],
                    showDivider: i != group.destinations.length - 1,
                  ),
              ],
            ),
          ),
      ];
    } else {
      final matches = [
        for (final group in groups)
          ...group.destinations.where((d) => d.matches(query)),
      ];
      body = matches.isEmpty
          ? [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(tokens.gapXl),
                  child: Text(
                    context.l10n.settingsSearchNoResults(_query.trim()),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ]
          : [
              SliverToBoxAdapter(
                child: SettingsGroup(
                  margin: margin,
                  children: [
                    for (var i = 0; i < matches.length; i++)
                      _itemFor(
                        matches[i],
                        showDivider: i != matches.length - 1,
                      ),
                  ],
                ),
              ),
            ];
    }

    return CustomScrollView(
      slivers: [
        AppSliverHeader.tabRoot(title: context.l10n.settingsTitle),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.gapLg + wideInset,
              tokens.gapSm,
              tokens.gapLg + wideInset,
              tokens.gapSm,
            ),
            child: AppSearchField(
              controller: _searchController,
              hintText: context.l10n.settingsSearchHint,
              clearTooltip: context.l10n.dialogClear,
              onChanged: (value) => setState(() => _query = value),
              onClear: () => setState(() => _query = ''),
            ),
          ),
        ),
        ...body,
        SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
        const SliverFillRemaining(hasScrollBody: false, child: SizedBox()),
      ],
    );
  }
}
