import 'dart:io';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/draft.dart';
import '../data/expense.dart';
import '../services/receipts.dart';
import '../services/settings_store.dart';
import '../widgets/expense_editor.dart';

/// Review screen: the photo beside the fields, so AI guesses can be checked.
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.expenseId});
  final String expenseId;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  Expense? _e;
  ExpenseDraft? _draft;
  Future<File?>? _photo;
  List<String> _categories = SettingsStore.defaultCategories;
  bool _busy = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await Db.instance.get(widget.expenseId);
    final cats = await SettingsStore().categories();
    if (!mounted) return;
    setState(() {
      _e = e;
      _draft = e == null ? null : ExpenseDraft.fromExpense(e);
      _categories = cats;
      _dirty = false;
      _photo = e == null || !e.hasPhoto ? null : Receipts.photoFile(e);
    });
  }

  Future<void> _run(Future<void> Function() action, {String? done, bool close = false}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (done != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
      if (close) {
        Navigator.of(context).pop();
        return;
      }
      await _load();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$err')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _saveEdits({bool markReviewed = false}) async {
    final e = _e, d = _draft;
    if (e == null || d == null) return;
    await _run(
      () => Receipts.saveEdits(e, d, markReviewed: markReviewed),
      done: markReviewed ? 'Marked as reviewed' : 'Saved',
    );
  }

  Future<void> _deletePhoto() async {
    final e = _e;
    if (e == null) return;
    if (!await _confirm(
      'Delete the photo?',
      'The transaction stays. The photo moves to the Drive bin, where you can restore it for 30 days.',
      'Delete photo',
    )) {
      return;
    }
    await _run(() => Receipts.deletePhoto(e), done: 'Photo deleted');
  }

  Future<void> _deleteAll() async {
    final e = _e;
    if (e == null) return;
    if (!await _confirm(
      'Delete this transaction?',
      'The photo moves to the Drive bin, where you can restore it for 30 days.',
      'Delete',
    )) {
      return;
    }
    await _run(() => Receipts.delete(e), done: 'Deleted', close: true);
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    final d = _draft;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(e == null || e.description.isEmpty ? 'Receipt' : e.description),
        actions: [
          IconButton(
            tooltip: 'Delete transaction',
            onPressed: e == null || _busy ? null : _deleteAll,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: e == null || d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
              children: [
                _photoView(theme),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Chip(
                      avatar: Icon(
                        e.status == 'Reviewed' ? Icons.check_circle_outline : Icons.rate_review_outlined,
                        size: 18,
                      ),
                      label: Text(e.status),
                    ),
                    const Spacer(),
                    if (e.hasPhoto)
                      TextButton.icon(
                        onPressed: _busy ? null : _deletePhoto,
                        icon: const Icon(Icons.hide_image_outlined),
                        label: const Text('Delete photo'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ExpenseEditor(
                  draft: d,
                  categories: _categories,
                  onChanged: () => setState(() => _dirty = true),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy || !_dirty ? null : () => _saveEdits(),
                        child: const Text('Save changes'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ||
                                d.missingDate ||
                                d.missingCategory ||
                                d.missingAmount ||
                                (e.status == 'Reviewed' && !_dirty)
                            ? null
                            : () => _saveEdits(markReviewed: true),
                        child: const Text('Mark reviewed'),
                      ),
                    ),
                  ],
                ),
                if (d.missingDate || d.missingCategory || d.missingAmount)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Fill in the date, category and amount to mark it reviewed.',
                        style: theme.textTheme.bodySmall),
                  ),
                const SizedBox(height: 16),
                if (e.fileName != null)
                  Text('Drive: ${e.fileName}', style: theme.textTheme.bodySmall),
                if (e.uploadState == UploadState.pending)
                  Text('Uploading to Drive…', style: theme.textTheme.bodySmall),
                if (e.uploadState == UploadState.failed) ...[
                  const SizedBox(height: 8),
                  SelectableText('Upload failed: ${e.uploadError ?? ''}',
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(Receipts.uploadPending),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry upload'),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _photoView(ThemeData theme) {
    final future = _photo;
    if (future == null) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.receipt_long_outlined, size: 48),
      );
    }
    return FutureBuilder<File?>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return SelectableText('Could not load the photo: ${snap.error}',
              style: TextStyle(color: theme.colorScheme.error));
        }
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
        }
        final file = snap.data;
        if (file == null) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: InteractiveViewer(maxScale: 6, child: Image.file(file, fit: BoxFit.contain)),
          ),
        );
      },
    );
  }
}
