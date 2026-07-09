import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MacosFileAccessService {
  MacosFileAccessService._();

  static const MethodChannel _channel = MethodChannel(
    'com.hxlive.termora/file_access',
  );
  static const String _prefsKey = 'document.securityScopedBookmarks.v1';

  static Map<String, String>? _bookmarkCache;
  static final Set<String> _activePaths = <String>{};

  static Future<bool> persistAccess(String path) async {
    if (!Platform.isMacOS || path.isEmpty) return false;
    try {
      final bookmark = await _channel.invokeMethod<String>('createBookmark', {
        'path': path,
      });
      if (bookmark == null || bookmark.isEmpty) return false;

      final bookmarks = await _loadBookmarks();
      bookmarks[path] = bookmark;
      await _saveBookmarks(bookmarks);
      await startAccessing(path);
      return true;
    } catch (e) {
      debugPrint('[FileAccess] persistAccess failed for $path: $e');
      return false;
    }
  }

  static Future<bool> startAccessing(String path) async {
    if (!Platform.isMacOS || path.isEmpty) return true;
    if (_activePaths.contains(path)) return true;

    final bookmarks = await _loadBookmarks();
    final bookmark = bookmarks[path];
    if (bookmark == null || bookmark.isEmpty) {
      return true;
    }

    try {
      final ok = await _channel.invokeMethod<bool>('startAccessing', {
        'path': path,
        'bookmark': bookmark,
      });
      if (ok == true) {
        _activePaths.add(path);
      }
      return ok ?? false;
    } catch (e) {
      debugPrint('[FileAccess] startAccessing failed for $path: $e');
      return false;
    }
  }

  static Future<void> stopAccessing(String path) async {
    if (!Platform.isMacOS || path.isEmpty || !_activePaths.remove(path)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopAccessing', {'path': path});
    } catch (e) {
      debugPrint('[FileAccess] stopAccessing failed for $path: $e');
    }
  }

  static Future<Map<String, String>> _loadBookmarks() async {
    if (_bookmarkCache != null) return _bookmarkCache!;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _bookmarkCache = <String, String>{};
        return _bookmarkCache!;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _bookmarkCache = decoded.map(
          (key, value) => MapEntry(key, value.toString()),
        );
      } else {
        _bookmarkCache = <String, String>{};
      }
    } catch (e) {
      debugPrint('[FileAccess] load bookmarks failed: $e');
      _bookmarkCache = <String, String>{};
    }
    return _bookmarkCache!;
  }

  static Future<void> _saveBookmarks(Map<String, String> bookmarks) async {
    _bookmarkCache = Map<String, String>.from(bookmarks);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_bookmarkCache));
  }
}
