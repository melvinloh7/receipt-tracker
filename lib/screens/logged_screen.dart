import 'dart:io';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/expense.dart';
import '../services/receipts.dart';
import 'receipt_screen.dart';

/// Every logged transaction, newest first. Filters come in Phase 3.
class LoggedScreen extends StatefulWidget {
  const LoggedScreen({super.key});

  @override
  State<LoggedScreen> createState() => _LoggedScreenState();
}

class _LoggedScreenState extends State<LoggedScreen> {
  late Future<List<Expense>> _items;

  @override
  void initState() {
    super.initState();
    _items = Db.instance.all();
    Db.instance.changes.addListener(_reload);
  }

  @override
  void dispose() {
    Db.instance.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _items = Db.instance.all());
  }

  Future<void> _refresh() async {
    await Receipts.uploadPending();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logged')),
      body: FutureBuilder<List<Expense>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: SelectableText('${snap.error}'));
          final items = snap.data;
          if (items == null) return const Center(child: CircularProgressIndicator());
          if (items.isEmpty) {
            return const Center(child: Text('Nothing logged yet. Snap a receipt to start.'));
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: EdgeInsets.only(bottom: 24 + MediaQuery.of(context).viewPadding.bottom),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _Row(expense: items[i]),
            ),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.expense});
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final theme = Theme.of(context);
    final date = e.dateValue;
    final thumb = e.thumbPath;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 48,
          height: 48,
          child: thumb != null && File(thumb).existsSync()
              ? Image.file(File(thumb), fit: BoxFit.cover)
              : ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.receipt_long_outlined),
                ),
        ),
      ),
      title: Text(e.description.isEmpty ? 'Receipt' : e.description),
      subtitle: e.aiState == AiState.reading
          ? const Row(children: [
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Reading receipt…'),
            ])
          : e.aiState == AiState.failed
              ? Text('AI couldn\'t read it · tap to retry',
                  style: TextStyle(color: theme.colorScheme.error))
              : Text.rich(
        TextSpan(children: [
          date == null
              ? TextSpan(text: 'Missing date', style: TextStyle(color: theme.colorScheme.error))
              : TextSpan(text: MaterialLocalizations.of(context).formatMediumDate(date)),
          const TextSpan(text: ' · '),
          e.category == null
              ? TextSpan(text: 'Missing category', style: TextStyle(color: theme.colorScheme.error))
              : TextSpan(text: e.category),
          if (e.status == 'Needs review')
            const TextSpan(text: ' · Needs review', style: TextStyle(color: Color(0xFFE0A100))),
        ]),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                e.amount == null ? '—' : '${e.currency == 'SGD' ? 'S\$' : '${e.currency} '}${(e.myShare ?? e.amount)!.toStringAsFixed(2)}',
                style: theme.textTheme.titleSmall,
              ),
              if (e.who.length > 1 && e.amount != null)
                Text('of ${e.amount!.toStringAsFixed(2)}', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(width: 8),
          _uploadIcon(context, e) ?? const SizedBox(width: 24),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReceiptScreen(expenseId: e.id)),
      ),
    );
  }

  Widget? _uploadIcon(BuildContext context, Expense e) {
    switch (e.uploadState) {
      case UploadState.pending:
        return const Tooltip(message: 'Uploading', child: Icon(Icons.cloud_upload_outlined));
      case UploadState.failed:
        return Tooltip(
          message: 'Upload failed. Pull down to retry.',
          child: Icon(Icons.cloud_off_outlined, color: Theme.of(context).colorScheme.error),
        );
      case UploadState.uploaded:
        return const Tooltip(message: 'Saved in Drive', child: Icon(Icons.cloud_done_outlined));
      case UploadState.none:
        return null;
    }
  }
}
