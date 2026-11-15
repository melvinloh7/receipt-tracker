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
      version: 1,
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
            notes TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
    _db = db;
    return db;
  }

  void _changed() => changes.value++;

  Future<void> insert(Expense e) async {
    await (await _database).insert('expenses', e.toMap());
    _changed();
  }

  Future<void> update(Expense e) async {
    e.updatedAt = DateTime.now();
    await (await _database).update('expenses', e.toMap(), where: 'id = ?', whereArgs: [e.id]);
    _changed();
  }

  Future<void> delete(String id) async {
    await (await _database).delete('expenses', where: 'id = ?', whereArgs: [id]);
    _changed();
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
      where: "upload_state IN ('pending', 'failed')",
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
