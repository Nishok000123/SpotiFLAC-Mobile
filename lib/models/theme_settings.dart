import 'package:flutter/material.dart';

const String kThemeModeKey = 'theme_mode';
const String kUseDynamicColorKey = 'use_dynamic_color';
const String kSeedColorKey = 'seed_color';
const String kUseAmoledKey = 'use_amoled';
const String kThemeStyleKey = 'theme_style';
const String kMornyeAccentKey = 'mornye_accent';

enum AppThemeStyle { material, mornye }

enum MornyeAccent { red, orange, green, teal, blue, purple, pink }

MornyeAccent mornyeAccentFromString(String? value) =>
    MornyeAccent.values.firstWhere(
      (accent) => accent.name == value,
      orElse: () => MornyeAccent.red,
    );

AppThemeStyle themeStyleFromString(String? value) =>
    AppThemeStyle.values.firstWhere(
      (style) => style.name == value,
      orElse: () => AppThemeStyle.material,
    );

/// Default Spotify green color for fallback
const int kDefaultSeedColor = 0xFF1DB954;

class ThemeSettings {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final int seedColorValue;
  final bool useAmoled;
  final AppThemeStyle style;
  final MornyeAccent mornyeAccent;

  const ThemeSettings({
    this.themeMode = ThemeMode.system,
    this.useDynamicColor = true,
    this.seedColorValue = kDefaultSeedColor,
    this.useAmoled = false,
    this.style = AppThemeStyle.material,
    this.mornyeAccent = MornyeAccent.red,
  });

  Color get seedColor => Color(seedColorValue);

  ThemeSettings copyWith({
    ThemeMode? themeMode,
    bool? useDynamicColor,
    int? seedColorValue,
    bool? useAmoled,
    AppThemeStyle? style,
    MornyeAccent? mornyeAccent,
  }) {
    return ThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      seedColorValue: seedColorValue ?? this.seedColorValue,
      useAmoled: useAmoled ?? this.useAmoled,
      style: style ?? this.style,
      mornyeAccent: mornyeAccent ?? this.mornyeAccent,
    );
  }

  Map<String, dynamic> toJson() => {
    kThemeModeKey: themeMode.name,
    kUseDynamicColorKey: useDynamicColor,
    kSeedColorKey: seedColorValue,
    kUseAmoledKey: useAmoled,
    kThemeStyleKey: style.name,
    kMornyeAccentKey: mornyeAccent.name,
  };

  factory ThemeSettings.fromJson(Map<String, dynamic> json) {
    return ThemeSettings(
      themeMode: themeModeFromString(json[kThemeModeKey] as String?),
      useDynamicColor: json[kUseDynamicColorKey] as bool? ?? true,
      seedColorValue: json[kSeedColorKey] as int? ?? kDefaultSeedColor,
      useAmoled: json[kUseAmoledKey] as bool? ?? false,
      style: themeStyleFromString(json[kThemeStyleKey] as String?),
      mornyeAccent: mornyeAccentFromString(json[kMornyeAccentKey] as String?),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ThemeSettings &&
        other.themeMode == themeMode &&
        other.useDynamicColor == useDynamicColor &&
        other.seedColorValue == seedColorValue &&
        other.useAmoled == useAmoled &&
        other.style == style &&
        other.mornyeAccent == mornyeAccent;
  }

  @override
  int get hashCode =>
      themeMode.hashCode ^
      useDynamicColor.hashCode ^
      seedColorValue.hashCode ^
      useAmoled.hashCode ^
      style.hashCode ^
      mornyeAccent.hashCode;
}

ThemeMode themeModeFromString(String? value) {
  if (value == null) return ThemeMode.system;
  return ThemeMode.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThemeMode.system,
  );
}
