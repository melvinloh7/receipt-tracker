import 'package:flutter/material.dart';

import '../services/image_pipeline.dart';
import '../services/receipts.dart';
import '../services/settings_store.dart';

/// After a scan: shows the compressed receipt, takes a short description and
/// (optionally) the date, then saves. The AI chat replaces this in Phase 2.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.scanPath});
  final String scanPath;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _descCtrl = TextEditingController();
  CompressedReceipt? _photo;
  Object? _error;
  DateTime? _date;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _compress();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _compress() async {
    try {
      final settings = await SettingsStore().compression();
      final photo = await compressReceipt(widget.scanPath, settings);
      if (mounted) setState(() => _photo = photo);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final photo = _photo;
    if (photo == null) return;
    setState(() => _saving = true);
    try {
      await Receipts.save(photo: photo, description: _descCtrl.text, date: _date);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved. Uploading to Drive in the background.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final bottom = MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('New receipt')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottom),
        children: [
          if (_error != null)
            SelectableText('Could not process the scan: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else if (photo == null)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Image.memory(photo.full, fit: BoxFit.contain),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(photo.summary, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _descCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Short description (optional)',
              hintText: 'e.g. Dinner at IKEA',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(_date == null
                ? 'Missing date'
                : MaterialLocalizations.of(context).formatMediumDate(_date!)),
            subtitle: const Text('Tap to set the date on the receipt'),
            onTap: _pickDate,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: photo == null || _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
