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
  ///
  /// If the main model stays busy (Google's "high demand" 503), tries the
  /// backup models from Settings in order, once each, before giving up.
  Future<String> generate({
    required List<Map<String, Object>> parts,
    String? system,
    bool json = false,
    String thinkingLevel = 'low',
    void Function(int attempt, int of)? onRetry,
  }) async {
    final main = await _settings.geminiModel();
    try {
      return await _generateWith(main,
          parts: parts, system: system, json: json, thinkingLevel: thinkingLevel, onRetry: onRetry);
    } on GeminiBusy catch (busy) {
      // Main model busy: try each backup in order, one request each.
      var last = busy;
      final tried = [main];
      for (final backup in await _settings.backupGeminiModels()) {
        if (tried.contains(backup)) continue;
        tried.add(backup);
        onRetry?.call(tried.length, tried.length);
        try {
          return await _generateWith(backup,
              busyTries: 1,
              parts: parts, system: system, json: json, thinkingLevel: thinkingLevel, onRetry: onRetry);
        } on GeminiBusy catch (e) {
          last = e;
        } on GeminiRateLimit {
          // That backup's own allowance is used up: move on to the next.
        }
      }
      if (tried.length == 1) rethrow;
      throw GeminiBusy('tried ${tried.join(', ')}', googleSaid: last.googleSaid);
    }
  }

  /// Waits between retries when Gemini is busy: demand spikes take a while.
  static const _busyWaits = [Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 30)];

  /// [busyTries]: how many requests to spend while Google reports "high
  /// demand" before giving up on this model (each one counts against the
  /// free daily allowance).
  Future<String> _generateWith(
    String model, {
    int busyTries = 2,
    required List<Map<String, Object>> parts,
    String? system,
    bool json = false,
    String thinkingLevel = 'low',
    void Function(int attempt, int of)? onRetry,
  }) async {
    final key = await _requireKey();
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
    var busy = 0;
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      final client = http.Client();
      try {
        final text = await _streamOnce(client, model, uri, key, body()).timeout(_timeout);
        return text;
      } on _HttpError catch (e) {
        if (e.status == 400 && useThinking && e.body.toLowerCase().contains('thinking')) {
          // This model doesn't accept that thinking level: retry straight
          // away without one.
          useThinking = false;
          lastError = e;
          continue;
        }
        if (e.status == 429) {
          // Free-tier quota. Wait only if Google asks for a short pause;
          // otherwise stop, rather than spend more of the quota.
          final limit = GeminiRateLimit.fromBody(e.body);
          final wait = limit.retryAfter;
          if (!limit.daily && wait != null && wait <= const Duration(seconds: 60) && attempt < _attempts) {
            onRetry?.call(attempt + 1, _attempts);
            client.close();
            await Future<void>.delayed(wait + const Duration(seconds: 1));
            continue;
          }
          throw limit;
        }
        // Otherwise retry only when Google says it is busy, and only a little.
        if (e.status != 503) rethrow;
        lastError = e;
        busy++;
        if (busy >= busyTries) throw GeminiBusy(model, googleSaid: GeminiBusy.describe(e.body));
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
        final busy = lastError is _HttpError && lastError.status == 503;
        await Future<void>.delayed(busy ? _busyWaits[attempt - 1] : Duration(seconds: attempt * 2));
      }
    }
    if (lastError is _HttpError && lastError.status == 503) {
      throw GeminiBusy(model, googleSaid: GeminiBusy.describe(lastError.body));
    }
    throw Exception('Could not reach Gemini after $_attempts tries: $lastError');
  }

  Future<String> _streamOnce(http.Client client, String model, Uri uri, String key, String body) async {
    // Every request sent counts against the free daily allowance.
    await _settings.countRequest(model);
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

/// Google's servers for the model are overloaded ("high demand"). Temporary;
/// worth retrying a little later.
class GeminiBusy implements Exception {
  GeminiBusy(this.model, {this.googleSaid});
  final String model;

  /// Google's own words, e.g. "503 UNAVAILABLE: This model is currently
  /// experiencing high demand…"
  final String? googleSaid;

  /// Pulls "code STATUS: message" out of a Google error body.
  static String? describe(String body) {
    try {
      final err = (jsonDecode(body) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      return '${err['code']} ${err['status']}: ${err['message']}';
    } catch (_) {
      return body.length > 300 ? '${body.substring(0, 300)}…' : body;
    }
  }

  @override
  String toString() => 'Gemini is busy right now ($model). The app retries automatically '
      'next time you open it, or tap Retry.'
      '${googleSaid == null ? '' : '\n\nGoogle said: $googleSaid'}';
}

/// Google's free tier said no: too many requests per minute, or the daily
/// allowance is used up.
class GeminiRateLimit implements Exception {
  GeminiRateLimit({required this.daily, this.retryAfter, required this.detail});

  final bool daily;
  final Duration? retryAfter;
  final String detail;

  factory GeminiRateLimit.fromBody(String body) {
    final m = RegExp(r'"retryDelay"\s*:\s*"([0-9.]+)s"').firstMatch(body);
    final secs = m == null ? null : double.tryParse(m.group(1)!);
    return GeminiRateLimit(
      daily: RegExp('PerDay', caseSensitive: false).hasMatch(body),
      retryAfter: secs == null ? null : Duration(milliseconds: (secs * 1000).round()),
      detail: body,
    );
  }

  @override
  String toString() => daily
      ? 'Gemini free limit reached: daily allowance used up. It resets daily (around 3pm-4pm Singapore time).'
      : 'Gemini free limit reached: too many requests in a short time'
          '${retryAfter == null ? '' : '. Try again in about ${retryAfter!.inSeconds + 1}s'}.';
}

class _HttpError implements Exception {
  _HttpError(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'Gemini call failed ($status): $body';
}
