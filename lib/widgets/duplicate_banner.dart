import 'package:flutter/material.dart';

import '../data/expense.dart';
import '../screens/receipt_screen.dart';
import '../services/receipts.dart';

/// Warns when another receipt has the same amount and date and a similar
/// merchant or description (e.g. the same receipt snapped twice).
class DuplicateBanner extends StatelessWidget {
  const DuplicateBanner({super.key, required this.expenseId});
  final String expenseId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Expense>>(
      future: Receipts.possibleDuplicates(expenseId),
      builder: (context, snap) {
        final dupes = snap.data;
        if (dupes == null || dupes.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final loc = MaterialLocalizations.of(context);
        return Card(
          color: theme.colorScheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.content_copy_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dupes.length == 1 ? 'Possible duplicate' : '${dupes.length} possible duplicates',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                const Text('Same amount and date as another receipt. Delete one if it was logged twice.'),
                for (final d in dupes)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ReceiptScreen(expenseId: d.id)),
                    ),
                    child: Text(
                      'Open "${d.description.isEmpty ? 'Receipt' : d.description}"'
                      '${d.dateValue == null ? '' : ', ${loc.formatMediumDate(d.dateValue!)}'}',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
