import 'dart:io';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/expense.dart';
import '../services/receipts.dart';
import 'receipt_screen.dart';

enum _Period { all, thisMonth, lastMonth, custom }

enum _StatusFilter { all, needsReview, reviewed }

/// Every logged transaction, newest first, with search, filters and a running total.
class LoggedScreen extends StatefulWidget {
  const LoggedScreen({super.key, this.onlyNeedsReview = false});

  /// Opens with the "Needs review" filter on (from the home screen count).
  final bool onlyNeedsReview;

  @override
  State<LoggedScreen> createState() => _LoggedScreenState();
}

class _LoggedScreenState extends State<LoggedScreen> {
  late Future<List<Expense>> _items;
  final _search = TextEditingController();
  _Period _period = _Period.all;
  DateTimeRange? _range;
  String? _category; // null = all; '' = missing category
  late _StatusFilter _status =
      widget.onlyNeedsReview ? _StatusFilter.needsReview : _StatusFilter.all;
  String? _person;

  static const _missing = '';

  @override
  void initState() {
    super.initState();
    _items = Db.instance.all();
    Db.instance.changes.addListener(_reload);
  }

  @override
  void dispose() {
    Db.instance.changes.removeListener(_reload);
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _items = Db.instance.all());
  }

  Future<void> _refresh() async {
    await Receipts.uploadPending();
    _reload();
  }

  DateTime _when(Expense e) => e.dateValue ?? e.createdAt;

  bool _inPeriod(Expense e) {
    final d = _when(e);
    final now = DateTime.now();
    switch (_period) {
      case _Period.all:
        return true;
      case _Period.thisMonth:
        return d.year == now.year && d.month == now.month;
      case _Period.lastMonth:
        final last = DateTime(now.year, now.month - 1);
        return d.year == last.year && d.month == last.month;
      case _Period.custom:
        final r = _range;
        if (r == null) return true;
        final day = DateTime(d.year, d.month, d.day);
        return !day.isBefore(r.start) && !day.isAfter(r.end);
    }
  }

  List<Expense> _filter(List<Expense> all) {
    final q = _search.text.trim().toLowerCase();
    return all.where((e) {
      if (!_inPeriod(e)) return false;
      if (_category != null) {
        if (_category == _missing ? e.category != null : e.category != _category) return false;
      }
      if (_status == _StatusFilter.needsReview && e.status != 'Needs review') return false;
      if (_status == _StatusFilter.reviewed && e.status != 'Reviewed') return false;
      if (_person != null && !e.who.contains(_person)) return false;
      if (q.isNotEmpty) {
        final hay = [e.description, e.merchant ?? '', e.category ?? '', e.notes ?? '', e.who.join(' '), e.paidWith ?? '']
            .join(' ')
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  String get _periodLabel {
    final loc = MaterialLocalizations.of(context);
    switch (_period) {
      case _Period.all:
        return 'All dates';
      case _Period.thisMonth:
        return 'This month';
      case _Period.lastMonth:
        return 'Last month';
      case _Period.custom:
        final r = _range;
        return r == null ? 'Pick dates' : '${loc.formatShortDate(r.start)} – ${loc.formatShortDate(r.end)}';
    }
  }

  Future<void> _pickPeriod() async {
    final choice = await showModalBottomSheet<_Period>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (p, label) in const [
            (_Period.all, 'All dates'),
            (_Period.thisMonth, 'This month'),
            (_Period.lastMonth, 'Last month'),
            (_Period.custom, 'Pick dates…'),
          ])
            ListTile(
              title: Text(label),
              trailing: _period == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, p),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _Period.custom) {
      final now = DateTime.now();
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 1),
        initialDateRange: _range,
      );
      if (r == null) return;
      setState(() {
        _period = _Period.custom;
        _range = r;
      });
    } else {
      setState(() => _period = choice);
    }
  }

  Future<T?> _pick<T>(String title, List<(T?, String)> options, T? current) {
    return showModalBottomSheet<T?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            for (final (value, label) in options)
              ListTile(
                title: Text(label),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: active,
          onSelected: (_) => onTap(),
          showCheckmark: false,
          avatar: const Icon(Icons.arrow_drop_down, size: 18),
        ),
      );

  Widget _totals(List<Expense> shown) {
    final theme = Theme.of(context);
    var sgd = 0.0;
    var other = 0;
    for (final e in shown) {
      final v = e.myShare ?? e.amount;
      if (v == null) continue;
      if (e.currency == 'SGD') {
        sgd += v;
      } else {
        other++;
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Text(
        '${shown.length} item${shown.length == 1 ? '' : 's'} · your share S\$${sgd.toStringAsFixed(2)}'
        '${other > 0 ? ' (+$other in other currencies)' : ''}',
        style: theme.textTheme.titleSmall,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logged')),
      body: FutureBuilder<List<Expense>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: SelectableText('${snap.error}'));
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          if (all.isEmpty) {
            return const Center(child: Text('Nothing logged yet. Snap a receipt to start.'));
          }
          final shown = _filter(all);
          final categories = {for (final e in all) if (e.category != null) e.category!}.toList()..sort();
          final people = {for (final e in all) ...e.who}.where((p) => p != 'Self').toList()..sort();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: 'Search description, merchant, people…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(_search.clear),
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  _chip(_periodLabel, _period != _Period.all, _pickPeriod),
                  _chip(
                    _category == null ? 'Category' : (_category == _missing ? 'Missing category' : _category!),
                    _category != null,
                    () async {
                      final v = await _pick<String>('Category', [
                        (null, 'All categories'),
                        (_missing, 'Missing category'),
                        for (final c in categories) (c, c),
                      ], _category);
                      if (mounted) setState(() => _category = v);
                    },
                  ),
                  _chip(
                    switch (_status) {
                      _StatusFilter.all => 'Status',
                      _StatusFilter.needsReview => 'Needs review',
                      _StatusFilter.reviewed => 'Reviewed',
                    },
                    _status != _StatusFilter.all,
                    () async {
                      final v = await _pick<_StatusFilter>('Status', const [
                        (_StatusFilter.all, 'Any status'),
                        (_StatusFilter.needsReview, 'Needs review'),
                        (_StatusFilter.reviewed, 'Reviewed'),
                      ], _status);
                      if (mounted) setState(() => _status = v ?? _StatusFilter.all);
                    },
                  ),
                  if (people.isNotEmpty)
                    _chip(_person ?? 'Person', _person != null, () async {
                      final v = await _pick<String>('Shared with', [
                        (null, 'Anyone'),
                        for (final p in people) (p, p),
                      ], _person);
                      if (mounted) setState(() => _person = v);
                    }),
                ]),
              ),
              _totals(shown),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: shown.isEmpty
                      ? ListView(children: const [
                          Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('Nothing matches these filters.')),
                          ),
                        ])
                      : ListView.separated(
                          padding: EdgeInsets.only(bottom: 24 + MediaQuery.of(context).viewPadding.bottom),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) => _Row(expense: shown[i]),
                        ),
                ),
              ),
            ],
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
