import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

/// Minimal Gemini client. Receipt parsing is added in Phase 2.
class GeminiClient {
  GeminiClient(this._settings);
  final SettingsStore _settings;

  static const _timeout = Duration(seconds: 60);
  static const _attempts = 3;

  Future<String> generateText(String prompt) async {
    final key = await _settings.geminiKey();
    if (key.isEmpty) throw StateError('No Gemini API key. Add it in Settings.');
    final model = await _settings.geminiModel();
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
    );
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
    });

    http.Response? r;
    Object? lastError;
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      // A fresh client per attempt, so a dropped connection is never reused.
      final client = http.Client();
      try {
        r = await client
            .post(
              uri,
              headers: {'x-goog-api-key': key, 'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(_timeout);
        if (r.statusCode == 503 || r.statusCode == 429) {
          lastError = Exception('Gemini busy (${r.statusCode}): ${r.body}');
          r = null;
        } else {
          break;
        }
      } on http.ClientException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      } finally {
        client.close();
      }
      if (attempt < _attempts) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }

    if (r == null) {
      throw Exception('Could not reach Gemini after $_attempts tries: $lastError');
    }
    if (r.statusCode != 200) {
      throw Exception('Gemini call failed (${r.statusCode}): ${r.body}');
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    final parts = decoded['candidates']?[0]?['content']?['parts'] as List?;
    if (parts == null || parts.isEmpty) return '';
    // Some models return a "thought" part first; use the last text part.
    final texts = [
      for (final p in parts)
        if (p is Map && p['text'] != null && p['thought'] != true) p['text'].toString(),
    ];
    return texts.isEmpty ? '' : texts.last.trim();
  }
}
