import 'dart:convert';

import 'expense.dart';

/// The editable fields of a transaction, as shown on the card.
/// The AI fills one in; you correct it; Save turns it into an [Expense].
class ExpenseDraft {
  ExpenseDraft({
    this.date,
    this.description = '',
    this.merchant,
    this.category,
    this.amount,
    this.currency = 'SGD',
    this.cardLast4,
    List<String>? who,
    this.customSplit,
    Set<String>? inferred,
    this.notesForUser,
  })  : who = who ?? ['Self'],
        inferred = inferred ?? {};

  DateTime? date;
  String description;
  String? merchant;

  /// One of your categories, or null for "Missing category".
  String? category;

  /// The whole bill, as paid.
  double? amount;
  String currency;

  /// Last 4 digits printed on the receipt, if any.
  String? cardLast4;

  /// People sharing the bill. "Self" is you.
  List<String> who;

  /// Custom amounts per person; null means split evenly.
  Map<String, double>? customSplit;

  /// Fields the AI guessed rather than read or was told (shown amber).
  Set<String> inferred;

  /// A short note from the AI, e.g. "Two totals found; used the one after discount."
  String? notesForUser;

  static const fieldDate = 'date';
  static const fieldDescription = 'description';
  static const fieldCategory = 'category';
  static const fieldAmount = 'amount';
  static const fieldWho = 'who';
  static const fieldCard = 'card_last4';

  /// Your share of [amount]: the whole bill if alone, otherwise your portion.
  double? get myShare {
    final a = amount;
    if (a == null) return null;
    final split = customSplit;
    if (split != null && split.containsKey('Self')) return split['Self'];
    if (!who.contains('Self')) return 0;
    if (who.length <= 1) return a;
    // Even split, rounded to the cent; any leftover cent goes to Self.
    final each = (a / who.length * 100).floor() / 100;
    final leftover = ((a - each * who.length) * 100).round() / 100;
    return double.parse((each + leftover).toStringAsFixed(2));
  }

  bool get missingDate => date == null;
  bool get missingCategory => category == null;
  bool get missingAmount => amount == null;

  /// Reviewed only when nothing was guessed and nothing is missing.
  bool get needsReview => inferred.isNotEmpty || missingDate || missingCategory || missingAmount;

  /// You changed a field, so it is no longer an AI guess.
  void confirm(String field) => inferred.remove(field);

  ExpenseDraft copy() => ExpenseDraft(
        date: date,
        description: description,
        merchant: merchant,
        category: category,
        amount: amount,
        currency: currency,
        cardLast4: cardLast4,
        who: List.of(who),
        customSplit: customSplit == null ? null : Map.of(customSplit!),
        inferred: Set.of(inferred),
        notesForUser: notesForUser,
      );

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// JSON as sent back to the AI when you correct something in the chat.
  Map<String, Object?> toJson() => {
        'date': date == null ? null : _iso(date!),
        'description': description,
        'merchant': merchant,
        'category': category,
        'amount': amount,
        'currency': currency,
        'card_last4': cardLast4,
        'who': who,
        'split': customSplit ?? 'even',
        'inferred': inferred.toList(),
      };

  factory ExpenseDraft.fromExpense(Expense e) {
    Map<String, double>? split;
    final raw = e.split;
    if (raw != null && raw.isNotEmpty && raw != 'even') {
      try {
        split = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
      } catch (_) {}
    }
    return ExpenseDraft(
      date: e.dateValue,
      description: e.description,
      merchant: e.merchant,
      category: e.category,
      amount: e.amount,
      currency: e.currency,
      cardLast4: e.paidWith,
      who: e.who.isEmpty ? ['Self'] : List.of(e.who),
      customSplit: split,
      inferred: Set.of(e.inferred),
    );
  }

  /// Writes the draft's fields onto [e] (photo and upload fields untouched).
  void applyTo(Expense e) {
    e
      ..date = date == null ? null : _iso(date!)
      ..description = description.trim()
      ..merchant = merchant
      ..category = category
      ..amount = amount
      ..currency = currency
      ..amountSgd = currency == 'SGD' ? amount : null
      ..myShare = myShare
      ..paidWith = cardLast4
      ..who = List.of(who)
      ..split = customSplit == null ? 'even' : jsonEncode(customSplit)
      ..inferred = inferred.toList()
      ..status = needsReview ? 'Needs review' : 'Reviewed';
  }
}
