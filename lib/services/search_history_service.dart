import 'package:shared_preferences/shared_preferences.dart';

/// Persists recent search queries entered by the user on the Home tab.
class SearchHistoryService {
  static const _key = 'search_history';
  static const _maxItems = 10;

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }

  static Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final history = List<String>.from(prefs.getStringList(_key) ?? []);
    history.remove(trimmed);
    history.insert(0, trimmed);
    if (history.length > _maxItems) history.removeLast();
    await prefs.setStringList(_key, history);
  }

  static Future<void> remove(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final history = List<String>.from(prefs.getStringList(_key) ?? []);
    history.remove(query);
    await prefs.setStringList(_key, history);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
