import 'package:flutter/material.dart';

import '../data/draft.dart';
import 'split_sheet.dart';

/// The editable expense card. Fields the AI guessed are marked amber; missing
/// ones are red. Editing a field marks it as confirmed by you.
///
/// The [draft] is edited in place; [onChanged] fires after every change.
class ExpenseEditor extends StatefulWidget {
  const ExpenseEditor({
    super.key,
    required this.draft,
    required this.categories,
    required this.onChanged,
    this.people = const ['Self'],
  });

  final ExpenseDraft draft;
  final List<String> categories;
  final VoidCallback onChanged;

  /// Saved people, offered by "Add person".
  final List<String> people;

  @override
  State<ExpenseEditor> createState() => _ExpenseEditorState();
}

class _ExpenseEditorState extends State<ExpenseEditor> {
  final _desc = TextEditingController();
  final _amount = TextEditingController();
  final _currency = TextEditingController();
  final _who = TextEditingController();
  final _card = TextEditingController();

  static const _amber = Color(0xFFE0A100);

  @override
  void initState() {
    super.initState();
    _fill();
  }

  @override
  void didUpdateWidget(covariant ExpenseEditor old) {
    super.didUpdateWidget(old);
    // A new draft (e.g. the AI applied a correction): show its values.
    if (!identical(old.draft, widget.draft)) _fill();
  }

  void _fill() {
    final d = widget.draft;
    _desc.text = d.description;
    _amount.text = d.amount == null ? '' : d.amount!.toStringAsFixed(2);
    _currency.text = d.currency;
    _who.text = d.who.join(', ');
    _card.text = d.cardLast4 ?? '';
  }

  @override
  void dispose() {
    _desc.dispose();
    _amount.dispose();
    _currency.dispose();
    _who.dispose();
    _card.dispose();
    super.dispose();
  }

  void _changed(String field) {
    widget.draft.confirm(field);
    widget.onChanged();
    setState(() {});
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.draft.date ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    widget.draft.date = picked;
    _changed(ExpenseDraft.fieldDate);
  }

  Future<void> _addPerson(String? name) async {
    var n = name;
    if (n == null) {
      final ctrl = TextEditingController();
      n = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Add someone'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Add')),
          ],
        ),
      );
      ctrl.dispose();
    }
    final clean = n?.trim() ?? '';
    final d = widget.draft;
    if (clean.isEmpty || d.who.any((w) => w.toLowerCase() == clean.toLowerCase())) return;
    d.who = [...d.who, clean];
    d.customSplit = null;
    _who.text = d.who.join(', ');
    _changed(ExpenseDraft.fieldWho);
  }

  Future<void> _editSplit() async {
    if (await showSplitSheet(context, widget.draft)) {
      widget.onChanged();
      setState(() {});
    }
  }

  String _money(double v) => '${widget.draft.currency} ${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final guessed = d.inferred;

    InputDecoration deco(String label, String field, {bool missing = false, String? hint}) {
      final isGuess = guessed.contains(field);
      final color = missing ? error : (isGuess ? _amber : null);
      return InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        enabledBorder: color == null
            ? null
            : OutlineInputBorder(borderSide: BorderSide(color: color, width: 1.6)),
        helperText: missing ? 'Missing' : (isGuess ? 'AI guess, please check' : null),
        helperStyle: color == null ? null : TextStyle(color: color),
        isDense: true,
      );
    }

    final dateMissing = d.missingDate;
    final dateGuess = guessed.contains(ExpenseDraft.fieldDate);
    final dateColor = dateMissing ? error : (dateGuess ? _amber : theme.colorScheme.outline);

    final share = d.myShare;
    final splitText = d.who.length <= 1
        ? null
        : d.customSplit != null
            ? 'Custom split: ${d.customSplit!.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(2)}').join(', ')}'
            : 'Split evenly between ${d.who.length}${share == null ? '' : ' · your share ${_money(share)}'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.notesForUser != null && d.notesForUser!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 18, color: _amber),
                const SizedBox(width: 8),
                Expanded(child: Text(d.notesForUser!)),
              ],
            ),
          ),
        // Date
        InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Date',
              border: const OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: dateColor, width: dateMissing || dateGuess ? 1.6 : 1),
              ),
              helperText: dateMissing ? 'Missing date · tap to set' : (dateGuess ? 'AI guess, please check' : null),
              helperStyle: TextStyle(color: dateColor),
              isDense: true,
              suffixIcon: const Icon(Icons.event_outlined),
            ),
            child: Text(
              dateMissing ? 'Missing date' : MaterialLocalizations.of(context).formatMediumDate(d.date!),
              style: dateMissing ? TextStyle(color: error) : null,
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _desc,
          textCapitalization: TextCapitalization.sentences,
          decoration: deco('Description', ExpenseDraft.fieldDescription, hint: 'e.g. Dinner at IKEA'),
          onChanged: (v) {
            d.description = v;
            _changed(ExpenseDraft.fieldDescription);
          },
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String?>(
          // Keyed by value so a new AI answer resets the shown selection.
          key: ValueKey('cat-${d.category}'),
          initialValue: d.category,
          isExpanded: true,
          decoration: deco('Category', ExpenseDraft.fieldCategory, missing: d.missingCategory),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text('Missing category', style: TextStyle(color: error)),
            ),
            for (final c in widget.categories) DropdownMenuItem<String?>(value: c, child: Text(c)),
          ],
          onChanged: (v) {
            d.category = v;
            _changed(ExpenseDraft.fieldCategory);
          },
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: TextField(
                controller: _currency,
                textCapitalization: TextCapitalization.characters,
                maxLength: 3,
                decoration: const InputDecoration(
                  labelText: 'Currency',
                  border: OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                ),
                onChanged: (v) {
                  if (v.trim().length == 3) {
                    d.currency = v.trim().toUpperCase();
                    widget.onChanged();
                    setState(() {});
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: deco('Amount (whole bill)', ExpenseDraft.fieldAmount, missing: d.missingAmount),
                onChanged: (v) {
                  d.amount = double.tryParse(v.replaceAll(',', '').trim());
                  _changed(ExpenseDraft.fieldAmount);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _who,
          textCapitalization: TextCapitalization.words,
          decoration: deco('Who', ExpenseDraft.fieldWho, hint: 'Self, Des'),
          onChanged: (v) {
            final names = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
            d.who = names.isEmpty ? ['Self'] : names;
            // Typing new names resets a custom split to even (custom splits come in Phase 3).
            d.customSplit = null;
            _changed(ExpenseDraft.fieldWho);
          },
        ),
        if (splitText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(splitText, style: theme.textTheme.bodySmall),
          ),
        Row(
          children: [
            PopupMenuButton<String?>(
              tooltip: 'Add person',
              onSelected: _addPerson,
              itemBuilder: (context) => [
                for (final p in widget.people)
                  if (!d.who.any((w) => w.toLowerCase() == p.toLowerCase()))
                    PopupMenuItem<String?>(value: p, child: Text(p)),
                const PopupMenuItem<String?>(value: null, child: Text('Someone new…')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.person_add_alt, size: 20),
                  SizedBox(width: 6),
                  Text('Add person'),
                ]),
              ),
            ),
            const Spacer(),
            if (d.who.length > 1)
              TextButton.icon(
                onPressed: _editSplit,
                icon: const Icon(Icons.call_split, size: 20),
                label: const Text('Split…'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _card,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: deco('Card last 4 (if printed)', ExpenseDraft.fieldCard).copyWith(counterText: ''),
          onChanged: (v) {
            final digits = v.replaceAll(RegExp(r'\D'), '');
            d.cardLast4 = digits.length == 4 ? digits : null;
            _changed(ExpenseDraft.fieldCard);
          },
        ),
      ],
    );
  }
}
