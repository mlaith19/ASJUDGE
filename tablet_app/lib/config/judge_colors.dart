import 'package:flutter/material.dart';

/// Shared judge/tablet color palette. Keys must match backend (server/src/constants/judgeColors.js).
class JudgeColors {
  JudgeColors._();

  static const List<JudgeColorEntry> palette = [
    JudgeColorEntry('red', Color(0xFFDC3545)),
    JudgeColorEntry('blue', Color(0xFF0D6EFD)),
    JudgeColorEntry('green', Color(0xFF198754)),
    JudgeColorEntry('orange', Color(0xFFFD7E14)),
    JudgeColorEntry('yellow', Color(0xFFFFC107)),
    JudgeColorEntry('purple', Color(0xFF6F42C1)),
    JudgeColorEntry('pink', Color(0xFFD63384)),
    JudgeColorEntry('teal', Color(0xFF20C997)),
    JudgeColorEntry('cyan', Color(0xFF0DCAF0)),
    JudgeColorEntry('lime', Color(0xFF84CC16)),
    JudgeColorEntry('indigo', Color(0xFF6610F2)),
    JudgeColorEntry('brown', Color(0xFF795548)),
    JudgeColorEntry('gold', Color(0xFFFFB300)),
    JudgeColorEntry('magenta', Color(0xFFC2185B)),
    JudgeColorEntry('dark_blue', Color(0xFF1E3A5F)),
  ];

  static Color? colorForKey(String? key) {
    if (key == null || key.isEmpty) return null;
    final k = key.trim().toLowerCase();
    // Palette key lookup (e.g. 'red', 'blue')
    for (final e in palette) {
      if (e.key == k) return e.color;
    }
    // Hex fallback (e.g. '#dc3545') — in case server sends hex instead of key
    if (k.startsWith('#') && (k.length == 7 || k.length == 9)) {
      try {
        final hexStr = k.length == 7 ? 'ff${k.substring(1)}' : k.substring(1);
        final colorInt = int.parse(hexStr, radix: 16);
        return Color(colorInt);
      } catch (_) {}
    }
    return null;
  }

  static String? keyForColor(Color color) {
    final hex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
    for (final e in palette) {
      final eHex = '#${e.color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
      if (eHex.toUpperCase() == hex.toUpperCase()) return e.key;
    }
    return null;
  }

  /// Hex string for injection / display (e.g. #198754).
  static String? hexForKey(String? key) {
    final c = colorForKey(key);
    if (c == null) return null;
    return '#${c.red.toRadixString(16).padLeft(2, '0')}${c.green.toRadixString(16).padLeft(2, '0')}${c.blue.toRadixString(16).padLeft(2, '0')}';
  }

  static bool isValidKey(String? key) => colorForKey(key) != null;
}

class JudgeColorEntry {
  final String key;
  final Color color;

  const JudgeColorEntry(this.key, this.color);
}
