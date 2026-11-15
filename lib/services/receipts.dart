import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db.dart';
import '../data/expense.dart';
import 'background.dart';
import 'drive_store.dart';
import 'image_pipeline.dart';

/// Saving receipts on the phone and uploading them to Drive in the background.
class Receipts {
  Receipts._();
  static bool _uploading = false;

  static String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = Random().nextInt(1 << 32).toRadixString(36);
    return '$now-$rand';
  }

  static Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Stores the compressed photo and thumbnail on the phone, records the
  /// transaction, and starts the Drive upload in the background.
  static Future<Expense> save({
    required CompressedReceipt photo,
    required String description,
    DateTime? date,
  }) async {
    final id = _newId();
    final full = File(p.join((await _dir('receipts')).path, '$id.jpg'));
    final thumb = File(p.join((await _dir('thumbs')).path, '$id.jpg'));
    await full.writeAsBytes(photo.full, flush: true);
    await thumb.writeAsBytes(photo.thumb, flush: true);

    final e = Expense(
      id: id,
      date: date == null ? null : _iso(date),
      description: description.trim(),
      localPath: full.path,
      thumbPath: thumb.path,
      photoBytes: photo.full.length,
      uploadState: UploadState.pending,
      // Phase 1 has no AI yet: amount and category are filled in later.
      inferred: const [],
    );
    await Db.instance.insert(e);
    uploadPending(); // not awaited: runs in the background
    return e;
  }

  /// Uploads everything still waiting (new receipts, or ones that failed).
  static Future<void> uploadPending() async {
    if (_uploading) return;
    _uploading = true;
    try {
      final pending = await Db.instance.pendingUploads();
      if (pending.isEmpty) return;
      await Background.run<(int, int)>(
        title: pending.length == 1 ? 'Saving receipt to Drive' : 'Saving ${pending.length} receipts to Drive',
        job: (report) async {
          var ok = 0, failed = 0;
          for (final e in pending) {
            report(
              pending.length == 1 ? (e.description.isEmpty ? 'Uploading' : e.description) : '${ok + failed} of ${pending.length} done',
              done: ok + failed,
              total: pending.length,
            );
            if (await _uploadOne(e)) {
              ok++;
            } else {
              failed++;
            }
          }
          return (ok, failed);
        },
        summary: (r) {
          final (ok, failed) = r;
          if (failed == 0) {
            final one = pending.length == 1 ? pending.first : null;
            return (
              ok == 1 ? 'Receipt saved to Drive' : '$ok receipts saved to Drive',
              one?.fileName ?? 'Open the app to review',
            );
          }
          return ('$failed receipt${failed == 1 ? '' : 's'} not uploaded', 'Will retry when you next open the app');
        },
      );
    } catch (_) {
      // Per-receipt errors are recorded on each receipt.
    } finally {
      _uploading = false;
    }
  }

  static Future<bool> _uploadOne(Expense e) async {
    final path = e.localPath;
    if (path == null || !File(path).existsSync()) {
      e.uploadState = UploadState.none;
      e.uploadError = 'Photo file missing on the phone';
      await Db.instance.update(e);
      return false;
    }
    try {
      final drive = DriveStore.instance;
      final folder = await drive.folderFor(e.dateValue);
      final name = await drive.uniqueName(folder, receiptBaseName(e.dateValue, e.description));
      final (fileId, link) = await drive.upload(await File(path).readAsBytes(), name, folder);
      e
        ..driveFileId = fileId
        ..driveLink = link
        ..fileName = name
        ..uploadState = UploadState.uploaded
        ..uploadError = null;
      // The full photo now lives in Drive; the phone keeps only the thumbnail.
      try {
        File(path).deleteSync();
      } catch (_) {}
      e.localPath = null;
      await Db.instance.update(e);
      return true;
    } catch (err) {
      e
        ..uploadState = UploadState.failed
        ..uploadError = err.toString();
      await Db.instance.update(e);
      return false;
    }
  }

  /// Full-size photo: from the phone if still there, otherwise from Drive
  /// (then kept in the app's cache).
  static Future<File?> photoFile(Expense e) async {
    final local = e.localPath;
    if (local != null && File(local).existsSync()) return File(local);
    final id = e.driveFileId;
    if (id == null) return null;
    final cache = File(p.join((await getTemporaryDirectory()).path, 'photos', '${e.id}.jpg'));
    if (cache.existsSync()) return cache;
    cache.parent.createSync(recursive: true);
    await cache.writeAsBytes(await DriveStore.instance.download(id), flush: true);
    return cache;
  }

  /// Deletes the transaction, its files on the phone, and moves the Drive copy to the bin.
  static Future<void> delete(Expense e) async {
    final id = e.driveFileId;
    if (id != null) await DriveStore.instance.trash(id);
    for (final path in [e.localPath, e.thumbPath]) {
      if (path != null) {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      }
    }
    await Db.instance.delete(e.id);
  }
}
