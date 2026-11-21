import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db.dart';
import '../data/draft.dart';
import '../data/expense.dart';
import 'background.dart';
import 'drive_store.dart';
import 'image_pipeline.dart';
import 'receipt_ai.dart';
import 'settings_store.dart';

/// Saving receipts, reading them with the AI, and uploading them to Drive,
/// all in the background so it carries on when you leave the app.
class Receipts {
  Receipts._();
  static bool _uploading = false;
  static bool _uploadAgain = false;

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

  /// AI reads in progress, by receipt id (so a re-tap doesn't start a second).
  static final _reading = <String, Future<ExpenseDraft?>>{};

  static bool isReading(String id) => _reading.containsKey(id);

  /// Saves the receipt straight away (photo, thumbnail, your note) with
  /// "Reading receipt…" status, and starts the AI read in the background.
  /// Returns the new receipt's id.
  static Future<String> start({required CompressedReceipt photo, required String note}) async {
    final id = _newId();
    final full = File(p.join((await _dir('receipts')).path, '$id.jpg'));
    final thumb = File(p.join((await _dir('thumbs')).path, '$id.jpg'));
    await full.writeAsBytes(photo.full, flush: true);
    await thumb.writeAsBytes(photo.thumb, flush: true);

    await Db.instance.insert(Expense(
      id: id,
      localPath: full.path,
      thumbPath: thumb.path,
      photoBytes: photo.full.length,
      uploadState: UploadState.pending,
      aiState: AiState.reading,
      aiNote: note.trim(),
    ));
    read(id); // not awaited: carries on if you leave the chat
    return id;
  }

  /// Runs (or re-runs) the AI read for a receipt and saves the result to it.
  /// With [correction], applies your chat reply to the current fields.
  /// Returns the result, or null if the AI couldn't read it (the reason is
  /// saved on the receipt).
  static Future<ExpenseDraft?> read(String id, {String? correction}) {
    final running = _reading[id];
    if (running != null && correction == null) return running;
    final job = _read(id, correction).whenComplete(() => _reading.remove(id));
    _reading[id] = job;
    return job;
  }

  static Future<ExpenseDraft?> _read(String id, String? correction) async {
    final e = await Db.instance.get(id);
    if (e == null) return null;
    await Db.instance.patch(id, {'ai_state': AiState.reading.name, 'ai_error': null});
    try {
      final photo = await _photoBytes(e);
      final settings = SettingsStore();
      final previous = correction == null ? null : ExpenseDraft.fromExpense(e);
      final draft = await Background.run<ExpenseDraft>(
        title: 'Reading receipt',
        job: (report) {
          report(correction == null ? 'Reading the receipt' : 'Applying your change');
          return ReceiptAi(settings).read(
            photo: photo,
            note: e.aiNote ?? '',
            previous: previous,
            correction: correction,
            onRetry: (attempt, of) => report('Connection dropped, retry $attempt of $of'),
          );
        },
        summary: (d) => (
          'Receipt read: ${_label(d)}',
          d.needsReview ? 'Needs review. Tap Logged to check it.' : 'Saved.',
        ),
        failure: (err) => ('Could not read the receipt', 'Open it in Logged to retry or fill it in'),
      );
      // Re-read the row: an upload may have finished in the meantime.
      final fresh = await Db.instance.get(id);
      if (fresh == null) return draft; // deleted meanwhile
      final oldBase = receiptBaseName(fresh.dateValue, fresh.description);
      draft.applyTo(fresh);
      fresh
        ..aiState = AiState.done
        ..aiError = null;
      await Db.instance.update(fresh);
      await _syncDriveName(fresh, oldBase);
      return draft;
    } catch (err) {
      await Db.instance.patch(id, {'ai_state': AiState.failed.name, 'ai_error': err.toString()});
      return null;
    } finally {
      uploadPending(); // the photo goes to Drive either way
    }
  }

  /// Restarts AI reads that were cut off (e.g. Android closed the app).
  static Future<void> resumeReading() async {
    for (final e in await Db.instance.withAiState(AiState.reading)) {
      if (!isReading(e.id)) read(e.id);
    }
  }

  static String _label(ExpenseDraft d) {
    final parts = <String>[
      if (d.description.isNotEmpty) d.description,
      if (d.amount != null) '${d.currency} ${d.amount!.toStringAsFixed(2)}',
    ];
    return parts.isEmpty ? 'receipt' : parts.join(' · ');
  }

  static Future<Uint8List?> _photoBytes(Expense e) async {
    final file = await photoFile(e);
    return file?.readAsBytes();
  }

  /// If the receipt is already in Drive and its date or description changed,
  /// renames the file and moves it to the right month folder.
  static Future<void> _syncDriveName(Expense e, String oldBase) async {
    final fileId = e.driveFileId;
    final newBase = receiptBaseName(e.dateValue, e.description);
    if (fileId == null || newBase == oldBase) return;
    final drive = DriveStore.instance;
    final folder = await drive.folderFor(e.dateValue);
    final name = await drive.uniqueName(folder, newBase);
    await drive.moveRename(fileId, name, folder);
    await Db.instance.patch(e.id, {'file_name': name});
    e.fileName = name;
  }

  /// Saves edits from the chat or review screen. If the date or description
  /// changed and the photo is in Drive, renames it and moves it.
  static Future<void> saveEdits(Expense e, ExpenseDraft draft, {bool markReviewed = false}) async {
    final oldBase = receiptBaseName(e.dateValue, e.description);
    draft.applyTo(e);
    if (markReviewed) {
      e.status = 'Reviewed';
      e.inferred = const [];
    }
    await Db.instance.update(e);
    await _syncDriveName(e, oldBase);
  }

  /// Removes the photo (Drive copy to the bin, thumbnail deleted) but keeps
  /// the transaction, which then shows a generic receipt icon.
  static Future<void> deletePhoto(Expense e) async {
    final id = e.driveFileId;
    if (id != null) await DriveStore.instance.trash(id);
    for (final path in [e.localPath, e.thumbPath]) {
      if (path != null) {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      }
    }
    e
      ..driveFileId = null
      ..driveLink = null
      ..fileName = null
      ..localPath = null
      ..thumbPath = null
      ..photoBytes = null
      ..uploadState = UploadState.none
      ..uploadError = null;
    await Db.instance.update(e);
  }

  /// Uploads everything still waiting (new receipts, or ones that failed).
  static Future<void> uploadPending() async {
    if (_uploading) {
      // A receipt became ready mid-run: go round once more afterwards.
      _uploadAgain = true;
      return;
    }
    _uploading = true;
    _uploadAgain = false;
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
      if (_uploadAgain) {
        _uploadAgain = false;
        uploadPending();
      }
    }
  }

  static Future<bool> _uploadOne(Expense queued) async {
    final e = await Db.instance.get(queued.id);
    if (e == null) return true; // deleted meanwhile
    final path = e.localPath;
    if (path == null || !File(path).existsSync()) {
      await Db.instance.patch(e.id, {
        'upload_state': UploadState.none.name,
        'upload_error': 'Photo file missing on the phone',
      });
      return false;
    }
    try {
      final drive = DriveStore.instance;
      final base = receiptBaseName(e.dateValue, e.description);
      final folder = await drive.folderFor(e.dateValue);
      final name = await drive.uniqueName(folder, base);
      final (fileId, link) = await drive.upload(await File(path).readAsBytes(), name, folder);
      await Db.instance.patch(e.id, {
        'drive_file_id': fileId,
        'drive_link': link,
        'file_name': name,
        'upload_state': UploadState.uploaded.name,
        'upload_error': null,
        'local_path': null,
      });
      // The full photo now lives in Drive; the phone keeps only the thumbnail.
      try {
        File(path).deleteSync();
      } catch (_) {}
      // You may have edited the date or description during the upload.
      final after = await Db.instance.get(e.id);
      if (after != null) await _syncDriveName(after, base);
      return true;
    } catch (err) {
      await Db.instance.patch(e.id, {
        'upload_state': UploadState.failed.name,
        'upload_error': err.toString(),
      });
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
