import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/db.dart';
import '../data/draft.dart';
import '../data/expense.dart';
import 'background.dart';
import 'google_auth.dart';

/// Copies transactions to the ledger's Expenses tab (one row per receipt,
/// matched by ID), and can restore them from there onto a new phone.
class LedgerSync {
  LedgerSync._();

  static const _tab = 'Expenses';
  static const _lastCol = 'R'; // 18 columns, A to R

  static const header = [
    'ID', 'Date', 'Description', 'Merchant', 'Category', 'Amount', 'Currency',
    'Amount (SGD)', 'My share (SGD)', 'Who', 'Split', 'Card last 4', 'Status',
    'AI-inferred fields', 'Photo link', 'Notes', 'Created', 'Updated',
  ];

  static Timer? _debounce;
  static bool _running = false;
  static bool _again = false;

  /// Starts listening for changes; each burst of edits syncs a few seconds later.
  static void start() {
    Db.instance.changes.addListener(schedule);
    schedule();
  }

  static void schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 4), run);
  }

  static String get _base =>
      'https://sheets.googleapis.com/v4/spreadsheets/${AppConfig.ledgerSpreadsheetId}';

  static Future<Map<String, String>> _headers({bool json = false}) async {
    final h = Map<String, String>.from(await GoogleAuth.instance.headers());
    if (json) h['Content-Type'] = 'application/json; charset=utf-8';
    return h;
  }

  static Never _fail(String what, http.Response r) =>
      throw Exception('$what failed (${r.statusCode}): ${r.body}');

  /// Numbers go in as numbers (not text) so the ledger can SUM them.
  static Object _money(double? v) => v == null ? '' : double.parse(v.toStringAsFixed(2));

  static List<Object> _row(Expense e) {
    final split = ExpenseDraft.fromExpense(e).customSplit;
    final status = switch (e.aiState) {
      AiState.failed => 'AI could not read',
      AiState.reading => 'Reading',
      _ => e.status,
    };
    return [
      e.id,
      e.date ?? '',
      e.description,
      e.merchant ?? '',
      e.category ?? '',
      _money(e.amount),
      e.currency,
      _money(e.amountSgd),
      e.currency == 'SGD' ? _money(e.myShare) : '',
      e.who.join(', '),
      split == null
          ? (e.who.length > 1 ? 'even' : '')
          : split.entries.map((x) => '${x.key} ${x.value.toStringAsFixed(2)}').join(', '),
      e.paidWith ?? '',
      status,
      e.inferred.join(', '),
      e.driveLink ?? '',
      e.notes ?? '',
      e.createdAt.toIso8601String().substring(0, 19).replaceFirst('T', ' '),
      e.updatedAt.toIso8601String().substring(0, 19).replaceFirst('T', ' '),
    ];
  }

  /// IDs in column A, mapped to their row numbers (row 1 is the header).
  static Future<Map<String, int>> _rowsById() async {
    final r = await http.get(
      Uri.parse('$_base/values/${Uri.encodeComponent('$_tab!A:A')}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail('Reading the Expenses tab', r);
    final values = (jsonDecode(r.body)['values'] as List?) ?? const [];
    final out = <String, int>{};
    for (var i = 1; i < values.length; i++) {
      final row = values[i] as List;
      if (row.isNotEmpty && row[0].toString().isNotEmpty) out[row[0].toString()] = i + 1;
    }
    return out;
  }

  static Future<int> _sheetId() async {
    final r = await http.get(
      Uri.parse('$_base?fields=sheets.properties(sheetId,title)'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail('Reading the ledger', r);
    for (final s in (jsonDecode(r.body)['sheets'] as List)) {
      final props = s['properties'] as Map<String, dynamic>;
      if (props['title'] == _tab) return props['sheetId'] as int;
    }
    throw Exception('The ledger has no $_tab tab');
  }

  /// Copies every changed receipt to the ledger and removes deleted ones.
  static Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    if (GoogleAuth.instance.user == null) return;
    _running = true;
    _again = false;
    try {
      final pending = await Db.instance.pendingSync();
      final deletions = await Db.instance.pendingDeletions();
      if (pending.isEmpty && deletions.isEmpty) return;
      await Background.run<void>(
        title: 'Updating the ledger',
        notifyWhenDone: false,
        job: (report) async {
          report('${pending.length + deletions.length} change(s)');
          final rows = await _rowsById();

          // Existing rows: update in place. New ones: append.
          final updates = <Map<String, Object>>[];
          final appends = <List<Object>>[];
          for (final e in pending) {
            final n = rows[e.id];
            if (n == null) {
              appends.add(_row(e));
            } else {
              updates.add({'range': '$_tab!A$n:$_lastCol$n', 'values': [_row(e)]});
            }
          }
          if (updates.isNotEmpty) {
            final r = await http.post(
              Uri.parse('$_base/values:batchUpdate'),
              headers: await _headers(json: true),
              body: jsonEncode({'valueInputOption': 'RAW', 'data': updates}),
            );
            if (r.statusCode != 200) _fail('Updating the ledger', r);
          }
          if (appends.isNotEmpty) {
            final r = await http.post(
              Uri.parse('$_base/values/${Uri.encodeComponent('$_tab!A:$_lastCol')}:append'
                  '?valueInputOption=RAW&insertDataOption=INSERT_ROWS'),
              headers: await _headers(json: true),
              body: jsonEncode({'values': appends}),
            );
            if (r.statusCode != 200) _fail('Adding to the ledger', r);
          }
          for (final e in pending) {
            await Db.instance.markSynced(e.id, e.updatedAt);
          }

          // Deleted receipts: remove their rows, bottom first so numbers hold.
          final toDelete = [for (final id in deletions) if (rows[id] != null) rows[id]!]
            ..sort((a, b) => b.compareTo(a));
          if (toDelete.isNotEmpty) {
            final sheetId = await _sheetId();
            final r = await http.post(
              Uri.parse('$_base:batchUpdate'),
              headers: await _headers(json: true),
              body: jsonEncode({
                'requests': [
                  for (final n in toDelete)
                    {
                      'deleteDimension': {
                        'range': {
                          'sheetId': sheetId,
                          'dimension': 'ROWS',
                          'startIndex': n - 1,
                          'endIndex': n,
                        },
                      },
                    },
                ],
              }),
            );
            if (r.statusCode != 200) _fail('Removing deleted receipts from the ledger', r);
          }
          await Db.instance.clearDeletions(deletions);
        },
        summary: (_) => ('Ledger updated', ''),
      );
    } catch (_) {
      // Stays pending; the next change or app start tries again.
    } finally {
      _running = false;
      if (_again) schedule();
    }
  }

  /// Copies receipts from the ledger that aren't on this phone (e.g. after
  /// switching phones). Photos stay in Drive and load when you open a receipt.
  /// Returns how many were added.
  static Future<int> restore() async {
    final r = await http.get(
      Uri.parse('$_base/values/${Uri.encodeComponent('$_tab!A2:$_lastCol')}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail('Reading the Expenses tab', r);
    final values = (jsonDecode(r.body)['values'] as List?) ?? const [];
    final have = await Db.instance.allIds();
    var added = 0;
    for (final raw in values) {
      final row = [for (final c in raw as List) c.toString()];
      String col(int i) => i < row.length ? row[i] : '';
      final id = col(0);
      if (id.isEmpty || have.contains(id)) continue;

      final link = col(14);
      final fileId = RegExp(r'/d/([A-Za-z0-9_-]+)').firstMatch(link)?.group(1);
      final who = col(9).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      Map<String, double>? split;
      if (col(10).isNotEmpty && col(10) != 'even') {
        split = {};
        for (final part in col(10).split(',')) {
          final m = RegExp(r'^(.*)\s+(-?[0-9.]+)$').firstMatch(part.trim());
          if (m != null) split[m.group(1)!.trim()] = double.parse(m.group(2)!);
        }
      }
      final status = col(12);
      await Db.instance.insertRestored(Expense(
        id: id,
        date: col(1).isEmpty ? null : col(1),
        description: col(2),
        merchant: col(3).isEmpty ? null : col(3),
        category: col(4).isEmpty ? null : col(4),
        amount: double.tryParse(col(5)),
        currency: col(6).isEmpty ? 'SGD' : col(6),
        amountSgd: double.tryParse(col(7)),
        myShare: double.tryParse(col(8)),
        who: who.isEmpty ? ['Self'] : who,
        split: split == null ? 'even' : jsonEncode(split),
        paidWith: col(11).isEmpty ? null : col(11),
        status: status == 'Reviewed' ? 'Reviewed' : 'Needs review',
        aiState: status == 'AI could not read' ? AiState.failed : AiState.done,
        inferred: col(13).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        driveFileId: fileId,
        driveLink: link.isEmpty ? null : link,
        uploadState: fileId == null ? UploadState.none : UploadState.uploaded,
        notes: col(15).isEmpty ? null : col(15),
        createdAt: DateTime.tryParse(col(16).replaceFirst(' ', 'T')),
        updatedAt: DateTime.tryParse(col(17).replaceFirst(' ', 'T')),
      ));
      added++;
    }
    return added;
  }
}
