import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'google_auth.dart';

/// Thin REST wrappers for the Drive and Sheets calls the app needs.
class GoogleApi {
  Future<Map<String, String>> _headers({bool json = false}) async {
    final h = Map<String, String>.from(await GoogleAuth.instance.headers());
    if (json) h['Content-Type'] = 'application/json; charset=utf-8';
    return h;
  }

  Never _fail(String what, http.Response r) =>
      throw Exception('$what failed (${r.statusCode}): ${r.body}');

  /// Active categories from the ledger's Categories tab.
  Future<List<String>> readCategories() async {
    final uri = Uri.parse(
      'https://sheets.googleapis.com/v4/spreadsheets/'
      '${AppConfig.ledgerSpreadsheetId}/values/${Uri.encodeComponent('Categories!A2:B')}',
    );
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode != 200) _fail('Reading categories', r);
    final rows = (jsonDecode(r.body)['values'] as List?) ?? const [];
    return [
      for (final row in rows.cast<List>())
        if (row.isNotEmpty &&
            row[0].toString().trim().isNotEmpty &&
            (row.length < 2 || row[1].toString().toUpperCase() != 'FALSE'))
          row[0].toString().trim(),
    ];
  }

  /// Name of the Receipts folder (proves Drive read access).
  Future<String> receiptsFolderName() async {
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files/${AppConfig.receiptsFolderId}?fields=name',
    );
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode != 200) _fail('Opening the Receipts folder', r);
    return jsonDecode(r.body)['name'] as String;
  }

  /// Creates and deletes an empty file in Receipts (proves Drive write access).
  Future<void> driveWriteCheck() async {
    final create = await http.post(
      Uri.parse('https://www.googleapis.com/drive/v3/files?fields=id'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'name': 'connection-test.txt',
        'mimeType': 'text/plain',
        'parents': [AppConfig.receiptsFolderId],
      }),
    );
    if (create.statusCode != 200) _fail('Writing to Drive', create);
    final id = jsonDecode(create.body)['id'] as String;
    final del = await http.delete(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$id'),
      headers: await _headers(),
    );
    if (del.statusCode != 204 && del.statusCode != 200) {
      _fail('Cleaning up the test file', del);
    }
  }
}
