import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

/// Minimal Gemini client. Receipt parsing is added in Phase 2.
class GeminiClient {
  GeminiClient(this._settings);
  final SettingsStore _settings;

  Future<String> generateText(String prompt) async {
    final key = await _settings.geminiKey();
    if (key.isEmpty) throw StateError('No Gemini API key. Add it in Settings.');
    final model = await _settings.geminiModel();
    final r = await http.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
      ),
      headers: {'x-goog-api-key': key, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
      }),
    );
    if (r.statusCode != 200) {
      throw Exception('Gemini call failed (${r.statusCode}): ${r.body}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final parts = body['candidates']?[0]?['content']?['parts'] as List?;
    return (parts?.isNotEmpty ?? false) ? parts!.first['text'].toString().trim() : '';
  }
}
