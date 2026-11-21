import 'package:flutter/material.dart';

import '../data/draft.dart';

/// Bottom sheet to split a bill evenly or by custom amounts.
/// Returns true if the split changed.
Future<bool> showSplitSheet(BuildContext context, ExpenseDraft draft) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _SplitSheet(draft: draft),
  );
  return changed ?? false;
}

class _SplitSheet extends StatefulWidget {
  const _SplitSheet({required this.draft});
  final ExpenseDraft draft;

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  late bool _custom = widget.draft.customSplit != null;
  late final Map<String, TextEditingController> _ctrls = {
    for (final name in widget.draft.who)
      name: TextEditingController(
        text: widget.draft.customSplit?[name]?.toStringAsFixed(2) ?? '',
      ),
  };

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _total => widget.draft.amount;

  double? _value(String name) => double.tryParse(_ctrls[name]!.text.replaceAll(',', '').trim());

  List<String> get _blanks => [for (final n in _ctrls.keys) if (_value(n) == null) n];

  double get _entered => _ctrls.keys.map(_value).whereType<double>().fold(0.0, (a, b) => a + b);

  /// What's left once the typed amounts are taken off the bill.
  double get _left => ((_total ?? 0) - _entered);

  /// Valid when the shares add up: either exactly, or one person left blank
  /// takes whatever remains.
  bool get _valid {
    if (_total == null) return false;
    if (_ctrls.keys.map(_value).whereType<double>().any((v) => v < 0)) return false;
    final blanks = _blanks.length;
    if (blanks == 0) return _left.abs() < 0.005;
    if (blanks == 1) return _left > -0.005;
    return false;
  }

  void _apply() {
    final d = widget.draft;
    if (!_custom) {
      d.customSplit = null;
    } else {
      final blanks = _blanks;
      d.customSplit = {
        for (final n in _ctrls.keys)
          n: _value(n) ?? (blanks.length == 1 ? double.parse(_left.toStringAsFixed(2)) : 0),
      };
    }
    d.confirm(ExpenseDraft.fieldWho);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = widget.draft.currency;
    final total = _total;
    final names = _ctrls.keys.toList();
    final blanks = _blanks;
    final String status;
    if (total == null) {
      status = 'Set the amount first.';
    } else if (blanks.length == 1) {
      status = '${blanks.first} takes the rest: $cur ${_left.toStringAsFixed(2)}';
    } else if (blanks.isEmpty) {
      status = _left.abs() < 0.005
          ? 'Adds up to $cur ${total.toStringAsFixed(2)}'
          : '$cur ${_left.toStringAsFixed(2)} left to assign';
    } else {
      status = '$cur ${_left.toStringAsFixed(2)} left to assign (leave at most one person blank)';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).viewPadding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Split the bill', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            total == null ? 'No amount yet' : 'Whole bill: $cur ${total.toStringAsFixed(2)}, ${names.length} people',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Split evenly'), icon: Icon(Icons.drag_handle)),
              ButtonSegment(value: true, label: Text('Custom amounts'), icon: Icon(Icons.tune)),
            ],
            selected: {_custom},
            onSelectionChanged: (v) => setState(() => _custom = v.first),
          ),
          const SizedBox(height: 16),
          if (!_custom)
            Text(
              total == null
                  ? 'Each person pays an equal share once the amount is set.'
                  : 'Each pays about $cur ${(total / names.length).toStringAsFixed(2)}; '
                      'any leftover cent goes to Self.',
            )
          else ...[
            for (final n in names)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: _ctrls[n],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: n,
                    prefixText: '$cur ',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: blanks.length == 1 && blanks.first == n ? 'the rest' : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Text(
              status,
              style: TextStyle(color: _valid ? theme.colorScheme.primary : theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: !_custom || _valid ? _apply : null,
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
