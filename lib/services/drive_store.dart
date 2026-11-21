import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'google_auth.dart';

/// Receipt photos in Drive: Life Dashboard / Receipts / 2026 / 11-Nov /.
class DriveStore {
  DriveStore._();
  static final DriveStore instance = DriveStore._();

  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final _folderCache = <String, String>{};

  Future<Map<String, String>> _headers({String? contentType}) async {
    final h = Map<String, String>.from(await GoogleAuth.instance.headers());
    if (contentType != null) h['Content-Type'] = contentType;
    return h;
  }

  static String _q(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Never _fail(String what, http.Response r) =>
      throw Exception('$what failed (${r.statusCode}): ${r.body}');

  /// The folder a receipt belongs in, created if needed. Undated receipts go
  /// to "Undated" until their date is known.
  Future<String> folderFor(DateTime? date) async {
    if (date == null) return _findOrCreate(AppConfig.receiptsFolderId, 'Undated');
    final year = await _findOrCreate(AppConfig.receiptsFolderId, '${date.year}');
    final month = '${date.month.toString().padLeft(2, '0')}-${_months[date.month - 1]}';
    return _findOrCreate(year, month);
  }

  Future<String> _findOrCreate(String parentId, String name) async {
    final key = '$parentId/$name';
    final cached = _folderCache[key];
    if (cached != null) return cached;

    final q = "'$parentId' in parents and name = '${_q(name)}' "
        "and mimeType = '$_folderMime' and trashed = false";
    final list = await http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {'q': q, 'fields': 'files(id)'}),
      headers: await _headers(),
    );
    if (list.statusCode != 200) _fail('Finding folder $name', list);
    final files = (jsonDecode(list.body)['files'] as List?) ?? const [];
    if (files.isNotEmpty) {
      return _folderCache[key] = files.first['id'] as String;
    }

    final create = await http.post(
      Uri.parse('https://www.googleapis.com/drive/v3/files?fields=id'),
      headers: await _headers(contentType: 'application/json; charset=utf-8'),
      body: jsonEncode({'name': name, 'mimeType': _folderMime, 'parents': [parentId]}),
    );
    if (create.statusCode != 200) _fail('Creating folder $name', create);
    return _folderCache[key] = jsonDecode(create.body)['id'] as String;
  }

  /// `base.jpg`, or `base-2.jpg`, `base-3.jpg`… if the name is taken.
  Future<String> uniqueName(String folderId, String base) async {
    final q = "'$folderId' in parents and name contains '${_q(base)}' and trashed = false";
    final r = await http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {'q': q, 'fields': 'files(name)'}),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail('Checking file names', r);
    final taken = {
      for (final f in (jsonDecode(r.body)['files'] as List? ?? const [])) f['name'] as String,
    };
    var name = '$base.jpg';
    var n = 2;
    while (taken.contains(name)) {
      name = '$base-${n++}.jpg';
    }
    return name;
  }

  /// Uploads a JPEG; returns its Drive file ID and web link.
  Future<(String, String?)> upload(Uint8List bytes, String name, String folderId) async {
    const boundary = 'receipt-tracker-boundary';
    final meta = jsonEncode({'name': name, 'parents': [folderId], 'mimeType': 'image/jpeg'});
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$meta\r\n'
          '--$boundary\r\n'
          'Content-Type: image/jpeg\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final r = await http.post(
      Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files'
        '?uploadType=multipart&fields=id,webViewLink',
      ),
      headers: await _headers(contentType: 'multipart/related; boundary=$boundary'),
      body: body.takeBytes(),
    );
    if (r.statusCode != 200) _fail('Uploading $name', r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['id'] as String, j['webViewLink'] as String?);
  }

  Future<Uint8List> download(String fileId) async {
    final r = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) _fail('Downloading the photo', r);
    return r.bodyBytes;
  }

  /// Renames a file and moves it into [folderId] (from wherever it is now).
  Future<void> moveRename(String fileId, String name, String folderId) async {
    final info = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?fields=parents'),
      headers: await _headers(),
    );
    if (info.statusCode != 200) _fail('Finding the photo in Drive', info);
    final parents = ((jsonDecode(info.body)['parents'] as List?) ?? const []).cast<String>();
    final query = <String, String>{'fields': 'id'};
    if (!parents.contains(folderId)) {
      query['addParents'] = folderId;
      if (parents.isNotEmpty) query['removeParents'] = parents.join(',');
    }
    final r = await http.patch(
      Uri.https('www.googleapis.com', '/drive/v3/files/$fileId', query),
      headers: await _headers(contentType: 'application/json; charset=utf-8'),
      body: jsonEncode({'name': name}),
    );
    if (r.statusCode != 200) _fail('Renaming the photo in Drive', r);
  }

  /// Moves a file to the Drive bin (recoverable for 30 days).
  Future<void> trash(String fileId) async {
    final r = await http.patch(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId'),
      headers: await _headers(contentType: 'application/json; charset=utf-8'),
      body: jsonEncode({'trashed': true}),
    );
    if (r.statusCode != 200 && r.statusCode != 404) _fail('Removing the photo from Drive', r);
  }
}
