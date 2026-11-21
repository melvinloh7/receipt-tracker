import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'settings_store.dart';

/// Gemini client: text and image requests, optionally JSON-only replies.
///
/// Replies are streamed (Server-Sent Events) so bytes keep flowing while the
/// model works; a silent long-held connection was being dropped on Mel's phone.
class GeminiClient {
  GeminiClient(this._settings);
  final SettingsStore _settings;

  static const _base = 'https://generativelanguage.googleapis.com/v1beta/models';
  static const _timeout = Duration(seconds: 90);
  static const _attempts = 3;

  /// Quick reachability check: fetches the model's description (no generation).
  Future<String> describeModel() async {
    final key = await _requireKey();
    final model = await _settings.geminiModel();
    final r = await http
        .get(Uri.parse('$_base/$model'), headers: {'x-goog-api-key': key})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('Model lookup failed (${r.statusCode}): ${r.body}');
    }
    final name = (jsonDecode(r.body) as Map<String, dynamic>)['displayName'];
    return '$model reachable${name == null ? '' : ' ($name)'}';
  }

  /// Generates text. [thinkingLevel]: minimal, low, medium or high.
  Future<String> generateText(
    String prompt, {
    String thinkingLevel = 'low',
    void Function(int attempt, int of)? onRetry,
  }) =>
      generate(
        parts: [
          {'text': prompt},
        ],
        thinkingLevel: thinkingLevel,
        onRetry: onRetry,
      );

  /// A JPEG image as a request part.
  static Map<String, Object> imagePart(List<int> jpeg) => {
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(jpeg)},
      };

  /// General call: [parts] (text and images), an optional [system]
  /// instruction, and [json] to ask for a JSON-only reply.
  Future<String> generate({
    required List<Map<String, Object>> parts,
    String? system,
    bool json = false,
    String thinkingLevel = 'low',
    void Function(int attempt, int of)? onRetry,
  }) async {
    final key = await _requireKey();
    final model = await _settings.geminiModel();
    final uri = Uri.parse('$_base/$model:streamGenerateContent?alt=sse');
    // Built per attempt: if the model rejects the thinking level, the next
    // attempt leaves it out and the model uses its own default.
    var useThinking = true;
    String body() => jsonEncode({
      if (system != null)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': [
        {'role': 'user', 'parts': parts},
      ],
      'generationConfig': {
        if (useThinking) 'thinkingConfig': {'thinkingLevel': thinkingLevel},
        if (json) 'responseMimeType': 'application/json',
      },
    });

    Object? lastError;
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      final client = http.Client();
      try {
        final text = await _streamOnce(client, uri, key, body()).timeout(_timeout);
        return text;
      } on _HttpError catch (e) {
        if (e.status == 400 && useThinking && e.body.toLowerCase().contains('thinking')) {
          // This model doesn't accept that thinking level: retry straight
          // away without one.
          useThinking = false;
          lastError = e;
          continue;
        }
        // Otherwise retry only when Google says it is busy.
        if (e.status != 503 && e.status != 429) rethrow;
        lastError = e;
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
        onRetry?.call(attempt + 1, _attempts);
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw Exception('Could not reach Gemini after $_attempts tries: $lastError');
  }

  Future<String> _streamOnce(http.Client client, Uri uri, String key, String body) async {
    final req = http.Request('POST', uri)
      ..headers['x-goog-api-key'] = key
      ..headers['Content-Type'] = 'application/json'
      ..body = body;
    final res = await client.send(req);
    if (res.statusCode != 200) {
      throw _HttpError(res.statusCode, await res.stream.bytesToString());
    }
    final out = StringBuffer();
    await for (final line
        in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      final chunk = jsonDecode(payload) as Map<String, dynamic>;
      final parts = chunk['candidates']?[0]?['content']?['parts'] as List?;
      for (final p in parts ?? const []) {
        if (p is Map && p['text'] != null && p['thought'] != true) {
          out.write(p['text']);
        }
      }
    }
    return out.toString().trim();
  }

  Future<String> _requireKey() async {
    final key = await _settings.geminiKey();
    if (key.isEmpty) throw StateError('No Gemini API key. Add it in Settings.');
    return key;
  }
}

class _HttpError implements Exception {
  _HttpError(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'Gemini call failed ($status): $body';
}
