import 'dart:convert';

import 'package:http/http.dart' as http;

/// Live tablet communication (register, heartbeat, config, commands) is WebSocket-only.
/// This service is used only for one-time/setup HTTP: judge list for setup form.
/// Discovery uses GET /api/ping (backend_discovery_service).
class JudgeListItem {
  const JudgeListItem({
    required this.letter,
    required this.name,
    required this.color,
  });
  final String letter;
  final String name;
  final String color;
}

class ApiService {
  ApiService({required this.baseUrl});

  final String baseUrl;

  String get _apiBase => baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';

  /// Fetches the list of judges for the setup dropdown. HTTP allowed for form/data load.
  Future<List<JudgeListItem>> getJudges() async {
    try {
      final uri = Uri.parse('${_apiBase}api/judges/list');
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return [];
      final list = jsonDecode(r.body);
      if (list is! List) return [];
      return list
          .map((e) => e is Map<String, dynamic>
              ? JudgeListItem(
                  letter: (e['letter'] as String?)?.trim().toUpperCase() ?? '',
                  name: (e['name'] as String?)?.trim() ?? '',
                  color: (e['color'] as String?)?.trim().toLowerCase() ?? '',
                )
              : null)
          .whereType<JudgeListItem>()
          .where((e) => e.letter.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
