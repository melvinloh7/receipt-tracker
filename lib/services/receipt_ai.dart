import 'dart:convert';
import 'dart:typed_data';

import '../data/draft.dart';
import 'gemini.dart';
import 'settings_store.dart';

/// Turns a receipt photo and/or your note into an [ExpenseDraft].
class ReceiptAi {
  ReceiptAi(this._settings) : _gemini = GeminiClient(_settings);
  final SettingsStore _settings;
  final GeminiClient _gemini;

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _system(List<String> categories, List<String> people, DateTime today, bool hasPhoto) => '''
You record one expense for Mel, who lives in Singapore, from a receipt photo and/or a short note Mel typed.
Reply with JSON only, exactly these keys:
{
  "date": "YYYY-MM-DD" or null,
  "description": string, 2 to 5 words describing the whole purchase (not line items), e.g. "Dinner at IKEA",
  "merchant": string or null,
  "category": one of the allowed categories, or null,
  "amount": number or null,
  "currency": ISO 4217 code,
  "card_last4": "1234" or null,
  "who": [names],
  "split": "even" or {"Name": amount, ...},
  "inferred": [field names],
  "notes_for_user": string or null
}

Rules:
- date: ${hasPhoto ? 'take it ONLY from the receipt. If the receipt shows no date, use null. Never use today\'s date or a date from the note for a photo.' : 'there is no photo, so take it from the note, resolving words like "yesterday" against today (${_iso(today)}). If the note gives no date, use today\'s date (${_iso(today)}) and include "date" in inferred.'}
- amount: the final amount actually paid, after discounts and including GST and service charge. If there are several totals and it is unclear which was paid, pick the most likely and explain in notes_for_user.
- currency: from the receipt; Singapore receipts and "\$" in Singapore are SGD.
- description: prefer Mel's words from the note, otherwise the merchant and what was bought. Keep it short.
- category: must be exactly one of: ${jsonEncode(categories)}. If none fits, or you cannot tell, use null.
- card_last4: only the last 4 digits of a card number actually printed on the receipt (e.g. "**** 7558"). Otherwise null.
- who: always start with "Self" unless the note says Mel did not take part. Add anyone the note says shared it ("shared with Des" -> ["Self", "Des"]). Match names to this list when they fit, using its spelling: ${jsonEncode(people)}.
- split: "even" unless the note gives amounts per person (e.g. "Des pays 40, rest mine" -> {"Des": 40, "Self": <rest>}).
- inferred: list every field ("date", "description", "category", "amount", "who", "card_last4") that you guessed rather than read clearly on the receipt or were told in the note. Include "category" unless it is obvious from the merchant. Include "amount" if the total was hard to read or ambiguous.
- notes_for_user: one short sentence only when something needs Mel's attention; otherwise null.
''';

  /// Reads a receipt. [previous] and [correction] are for follow-up messages
  /// in the chat ("category is Family").
  Future<ExpenseDraft> read({
    Uint8List? photo,
    required String note,
    ExpenseDraft? previous,
    String? correction,
    void Function(int attempt, int of)? onRetry,
  }) async {
    final categories = await _settings.categories();
    final people = await _settings.people();
    final today = DateTime.now();

    final text = StringBuffer();
    if (note.trim().isNotEmpty) {
      text.writeln('Mel\'s note: "${note.trim()}"');
    } else {
      text.writeln('Mel added no note; use the receipt only.');
    }
    if (previous != null && correction != null) {
      text
        ..writeln('Your previous answer was: ${jsonEncode(previous.toJson())}')
        ..writeln('Mel\'s correction: "${correction.trim()}"')
        ..writeln('Apply the correction and return the full updated JSON. Fields Mel corrected are no longer inferred.');
    }

    final raw = await _gemini.generate(
      system: _system(categories, people, today, photo != null),
      parts: [
        if (photo != null) GeminiClient.imagePart(photo),
        {'text': text.toString()},
      ],
      json: true,
      thinkingLevel: 'low',
      onRetry: onRetry,
    );
    return _parse(raw, categories, people, hasPhoto: photo != null);
  }

  ExpenseDraft _parse(String raw, List<String> categories, List<String> people, {required bool hasPhoto}) {
    // Tolerate a ```json fence or stray text around the object.
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) throw FormatException('The AI did not return JSON: $raw');
    final j = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;

    DateTime? date;
    final d = j['date'];
    if (d is String) date = DateTime.tryParse(d);

    // Category must be one of yours, matched case-insensitively; otherwise missing.
    String? category;
    final c = j['category'];
    if (c is String) {
      for (final known in categories) {
        if (known.toLowerCase() == c.trim().toLowerCase()) category = known;
      }
    }

    double? amount;
    final a = j['amount'];
    if (a is num) amount = a.toDouble();
    if (a is String) amount = double.tryParse(a.replaceAll(RegExp(r'[^0-9.\-]'), ''));

    String? card;
    final k = j['card_last4'];
    if (k != null) {
      final digits = k.toString().replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 4) card = digits.substring(digits.length - 4);
    }

    // Names: use your saved spelling when it matches; keep "Self" first.
    final who = <String>[];
    final w = j['who'];
    if (w is List) {
      for (final n in w) {
        final name = n.toString().trim();
        if (name.isEmpty) continue;
        final match = people.firstWhere(
          (p) => p.toLowerCase() == name.toLowerCase(),
          orElse: () => name.toLowerCase() == 'self' ? 'Self' : name,
        );
        if (!who.contains(match)) who.add(match);
      }
    }
    if (who.isEmpty) who.add('Self');
    if (who.remove('Self')) who.insert(0, 'Self');

    Map<String, double>? split;
    final s = j['split'];
    if (s is Map) {
      final parsed = <String, double>{};
      s.forEach((key, value) {
        if (value is num) {
          final name = key.toString().toLowerCase() == 'self' ? 'Self' : key.toString();
          parsed[name] = value.toDouble();
        }
      });
      if (parsed.isNotEmpty) split = parsed;
    }

    final inferred = <String>{
      for (final f in (j['inferred'] as List? ?? const [])) f.toString(),
    };
    // A category the AI proposed but that isn't on your list counts as missing, not guessed.
    if (category == null) inferred.remove('category');

    final currency = (j['currency'] as String?)?.trim().toUpperCase();
    return ExpenseDraft(
      date: date,
      description: (j['description'] as String?)?.trim() ?? '',
      merchant: (j['merchant'] as String?)?.trim(),
      category: category,
      amount: amount,
      currency: currency == null || currency.length != 3 ? 'SGD' : currency,
      cardLast4: card,
      who: who,
      customSplit: split,
      inferred: inferred,
      notesForUser: (j['notes_for_user'] as String?)?.trim(),
    );
  }
}
