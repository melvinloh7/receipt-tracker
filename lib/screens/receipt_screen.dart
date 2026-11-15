import 'dart:io';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/expense.dart';
import '../services/receipts.dart';

/// One transaction: the photo (zoomable) and its details.
/// Editing and "Mark reviewed" arrive in Phase 2.
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.expenseId});
  final String expenseId;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  Expense? _e;
  Future<File?>? _photo;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await Db.instance.get(widget.expenseId);
    if (!mounted) return;
    setState(() {
      _e = e;
      _photo = e == null || !e.hasPhoto ? null : Receipts.photoFile(e);
    });
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    await Receipts.uploadPending();
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    final e = _e;
    if (e == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: const Text('The photo moves to the Drive bin, where you can restore it for 30 days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await Receipts.delete(e);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(e == null || e.description.isEmpty ? 'Receipt' : e.description),
        actions: [
          IconButton(
            tooltip: 'Delete',
            onPressed: e == null || _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: e == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
              children: [
                _photoView(theme),
                const SizedBox(height: 16),
                _field('Date', e.dateValue == null ? null : MaterialLocalizations.of(context).formatMediumDate(e.dateValue!), missing: 'Missing date'),
                _field('Description', e.description.isEmpty ? null : e.description),
                _field('Category', e.category, missing: 'Missing category'),
                _field('Amount', e.amount == null ? null : '${e.currency} ${e.amount!.toStringAsFixed(2)}'),
                _field('Who', e.who.join(', ')),
                _field('Status', e.status),
                _field('Drive file', e.fileName),
                if (e.photoBytes != null) _field('Photo size', '${(e.photoBytes! / 1024).round()} KB'),
                if (e.uploadState == UploadState.failed) ...[
                  const SizedBox(height: 8),
                  SelectableText('Upload failed: ${e.uploadError ?? ''}',
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _retry,
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
        height: 160,
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
        final file = snap.data;
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
        }
        if (file == null) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: InteractiveViewer(maxScale: 6, child: Image.file(file, fit: BoxFit.contain)),
          ),
        );
      },
    );
  }

  Widget _field(String label, String? value, {String? missing}) {
    final theme = Theme.of(context);
    final shown = value ?? missing ?? '—';
    final isMissing = value == null && missing != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          Expanded(
            child: Text(shown, style: isMissing ? TextStyle(color: theme.colorScheme.error) : null),
          ),
        ],
      ),
    );
  }
}
