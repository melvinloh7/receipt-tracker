import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'expense.dart';

/// The phone's own database: what the app runs from day to day.
class Db {
  Db._();
  static final Db instance = Db._();

  /// Bumped whenever expenses change, so screens can refresh themselves.
  final changes = ValueNotifier<int>(0);

  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = p.join(await getDatabasesPath(), 'receipts.db');
    final db = await openDatabase(
      path,
      version: 3,
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute("ALTER TABLE expenses ADD COLUMN ai_state TEXT NOT NULL DEFAULT 'none'");
          await db.execute('ALTER TABLE expenses ADD COLUMN ai_note TEXT');
          await db.execute('ALTER TABLE expenses ADD COLUMN ai_error TEXT');
        }
        if (from < 3) {
          await db.execute("ALTER TABLE expenses ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'");
          await db.execute('CREATE TABLE IF NOT EXISTS deletions (id TEXT PRIMARY KEY)');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE expenses (
            id TEXT PRIMARY KEY,
            date TEXT,
            description TEXT NOT NULL DEFAULT '',
            merchant TEXT,
            category TEXT,
            amount REAL,
            currency TEXT NOT NULL DEFAULT 'SGD',
            amount_sgd REAL,
            my_share REAL,
            who TEXT,
            split TEXT,
            paid_with TEXT,
            status TEXT NOT NULL DEFAULT 'Needs review',
            inferred TEXT,
            drive_file_id TEXT,
            drive_link TEXT,
            file_name TEXT,
            local_path TEXT,
            thumb_path TEXT,
            upload_state TEXT NOT NULL DEFAULT 'none',
            upload_error TEXT,
            photo_bytes INTEGER,
            ai_state TEXT NOT NULL DEFAULT 'none',
            ai_note TEXT,
            ai_error TEXT,
            notes TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            sync_state TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
        // Receipts deleted on the phone, still to be removed from the ledger.
        await db.execute('CREATE TABLE deletions (id TEXT PRIMARY KEY)');
      },
    );
    _db = db;
    return db;
  }

  void _changed() => changes.value++;

  // Every change marks the receipt for syncing to the ledger.
  static const _syncPending = {'sync_state': 'pending'};

  Future<void> insert(Expense e) async {
    await (await _database).insert('expenses', {...e.toMap(), ..._syncPending});
    _changed();
  }

  /// Adds a receipt restored from the ledger (already in sync).
  Future<void> insertRestored(Expense e) async {
    await (await _database).insert(
      'expenses',
      {...e.toMap(), 'sync_state': 'synced'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _changed();
  }

  Future<void> update(Expense e) async {
    e.updatedAt = DateTime.now();
    await (await _database).update(
      'expenses',
      {...e.toMap(), ..._syncPending},
      where: 'id = ?',
      whereArgs: [e.id],
    );
    _changed();
  }

  /// Updates only the given columns, so background work (uploads, AI) never
  /// overwrites edits you made in the meantime.
  Future<void> patch(String id, Map<String, Object?> values) async {
    await (await _database).update(
      'expenses',
      {...values, ..._syncPending, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  Future<List<Expense>> withAiState(AiState state) async {
    final rows = await (await _database).query('expenses', where: 'ai_state = ?', whereArgs: [state.name]);
    return rows.map(Expense.fromMap).toList();
  }

  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
    await db.insert('deletions', {'id': id}, conflictAlgorithm: ConflictAlgorithm.ignore);
    _changed();
  }

  // ---- Ledger sync ----

  /// Receipts changed since they were last copied to the ledger
  /// (skipping ones the AI is still reading).
  Future<List<Expense>> pendingSync() async {
    final rows = await (await _database).query(
      'expenses',
      where: "sync_state = 'pending' AND ai_state != 'reading'",
      orderBy: 'created_at ASC',
    );
    return rows.map(Expense.fromMap).toList();
  }

  /// Marks a receipt as copied, unless it changed again since [readAt].
  Future<void> markSynced(String id, DateTime readAt) async {
    await (await _database).rawUpdate(
      "UPDATE expenses SET sync_state = 'synced' WHERE id = ? AND updated_at = ?",
      [id, readAt.toIso8601String()],
    );
  }

  Future<List<String>> pendingDeletions() async {
    final rows = await (await _database).query('deletions');
    return rows.map((r) => r['id'] as String).toList();
  }

  Future<void> clearDeletions(Iterable<String> ids) async {
    final db = await _database;
    for (final id in ids) {
      await db.delete('deletions', where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<Set<String>> allIds() async {
    final rows = await (await _database).query('expenses', columns: ['id']);
    return {for (final r in rows) r['id'] as String};
  }

  Future<Expense?> get(String id) async {
    final rows = await (await _database).query('expenses', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Expense.fromMap(rows.first);
  }

  /// Newest first: by receipt date, falling back to when it was logged.
  Future<List<Expense>> all() async {
    final rows = await (await _database).query(
      'expenses',
      orderBy: 'COALESCE(date, substr(created_at, 1, 10)) DESC, created_at DESC',
    );
    return rows.map(Expense.fromMap).toList();
  }

  Future<List<Expense>> pendingUploads() async {
    final rows = await (await _database).query(
      'expenses',
      // Wait for the AI before uploading, so the Drive name is final.
      where: "upload_state IN ('pending', 'failed') AND ai_state != 'reading'",
      orderBy: 'created_at ASC',
    );
    return rows.map(Expense.fromMap).toList();
  }

  Future<int> needsReviewCount() async {
    final r = await (await _database)
        .rawQuery("SELECT COUNT(*) AS n FROM expenses WHERE status = 'Needs review'");
    return (r.first['n'] as int?) ?? 0;
  }
}
