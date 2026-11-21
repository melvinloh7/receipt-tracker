import 'dart:async';

import 'package:flutter/material.dart';

import '../data/draft.dart';
import '../services/background.dart';
import '../services/google_api.dart';
import '../services/image_pipeline.dart';
import '../services/receipt_ai.dart';
import '../services/receipts.dart';
import '../services/settings_store.dart';
import '../widgets/expense_editor.dart';

class _Msg {
  _Msg(this.text, {this.fromUser = false, this.isError = false});
  final String text;
  final bool fromUser;
  final bool isError;
}

/// After a photo: a short chat with the AI, which fills in the expense card.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.scanPath});
  final String scanPath;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _settings = SettingsStore();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Future<CompressedReceipt> _photoFuture;
  CompressedReceipt? _photo;
  Object? _photoError;
  List<String> _categories = SettingsStore.defaultCategories;
  ExpenseDraft? _draft;
  String _firstNote = '';
  bool _thinking = false;
  String? _thinkingNote;
  bool _saving = false;
  final _messages = <_Msg>[
    _Msg('Add a short note, e.g. "dinner at Ikea, shared with Des", or just tap Read receipt.'),
  ];

  @override
  void initState() {
    super.initState();
    _photoFuture = _compress();
    _photoFuture.ignore(); // errors are shown on screen
    _loadCategories();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<CompressedReceipt> _compress() async {
    try {
      final photo = await compressReceipt(widget.scanPath, await _settings.compression());
      if (mounted) setState(() => _photo = photo);
      return photo;
    } catch (e) {
      if (mounted) setState(() => _photoError = e);
      rethrow;
    }
  }

  Future<void> _loadCategories() async {
    final cached = await _settings.categories();
    if (mounted) setState(() => _categories = cached);
    // Refresh from the ledger quietly; keep the cached list if offline.
    try {
      final fresh = await GoogleApi().readCategories();
      if (fresh.isNotEmpty) {
        await _settings.saveCategories(fresh);
        if (mounted) setState(() => _categories = fresh);
      }
    } catch (_) {}
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _say(_Msg m) {
    if (!mounted) return;
    setState(() => _messages.add(m));
    _scrollToEnd();
  }

  String _summary(ExpenseDraft d) {
    final parts = <String>[
      if (d.description.isNotEmpty) d.description,
      if (d.amount != null) '${d.currency} ${d.amount!.toStringAsFixed(2)}',
    ];
    return parts.isEmpty ? 'Receipt read' : parts.join(' · ');
  }

  Future<void> _send([String? preset]) async {
    if (_thinking) return;
    final text = (preset ?? _input.text).trim();
    final isCorrection = _draft != null;
    if (isCorrection && text.isEmpty) return;
    _input.clear();
    if (text.isNotEmpty) _say(_Msg(text, fromUser: true));
    if (!isCorrection) _firstNote = text;

    setState(() {
      _thinking = true;
      _thinkingNote = null;
    });
    _scrollToEnd();
    await Background.ensurePermission();

    try {
      final photo = await _photoFuture;
      final previous = _draft?.copy();
      final result = await Background.run<ExpenseDraft>(
        title: 'Reading receipt',
        job: (report) async {
          report(isCorrection ? 'Applying your change' : 'Reading the receipt');
          return ReceiptAi(_settings).read(
            photo: photo.full,
            note: _firstNote,
            previous: isCorrection ? previous : null,
            correction: isCorrection ? text : null,
            onRetry: (attempt, of) {
              report('Connection dropped, retry $attempt of $of');
              if (mounted) setState(() => _thinkingNote = 'Connection dropped, retry $attempt of $of');
            },
          );
        },
        summary: (d) => ('Receipt read: ${_summary(d)}', 'Open the app to check and save'),
        failure: (e) => ('Could not read the receipt', 'Open the app to fill it in yourself or try again'),
      );
      if (!mounted) return;
      setState(() => _draft = result);
      final missing = <String>[
        if (result.missingDate) 'date',
        if (result.missingCategory) 'category',
        if (result.missingAmount) 'amount',
      ];
      _say(_Msg([
        isCorrection ? 'Updated.' : 'Here\'s what I found.',
        if (result.inferred.isNotEmpty) 'Amber fields are my guesses; please check them.',
        if (missing.isNotEmpty) 'Missing: ${missing.join(', ')}.',
        if (result.inferred.isEmpty && missing.isEmpty) 'Everything came straight off the receipt.',
      ].join(' ')));
    } catch (e) {
      _say(_Msg(
        'I couldn\'t read it: $e\nYou can fill in the card yourself, or send your note again to retry.',
        isError: true,
      ));
      // Give a blank card so it can still be saved by hand.
      if (mounted && _draft == null) setState(() => _draft = ExpenseDraft());
    } finally {
      if (mounted) {
        setState(() {
          _thinking = false;
          _thinkingNote = null;
        });
      }
    }
  }

  Future<void> _save() async {
    final photo = _photo;
    if (photo == null) return;
    final draft = _draft ?? ExpenseDraft();
    setState(() => _saving = true);
    try {
      await Receipts.save(photo: photo, draft: draft);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(draft.needsReview
            ? 'Saved as Needs review. Uploading to Drive in the background.'
            : 'Saved. Uploading to Drive in the background.'),
      ));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  void _showPhoto() {
    final photo = _photo;
    if (photo == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(maxScale: 6, child: Image.memory(photo.full)),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Msg m) {
    final theme = Theme.of(context);
    final bg = m.fromUser
        ? theme.colorScheme.primaryContainer
        : m.isError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerHighest;
    return Align(
      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: SelectableText(m.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final draft = _draft;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('New receipt')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // Receipt thumbnail; tap to see it full screen.
                Center(
                  child: GestureDetector(
                    onTap: _showPhoto,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 180,
                        child: _photoError != null
                            ? Center(
                                child: Text('Could not process the photo: $_photoError',
                                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                              )
                            : photo == null
                                ? const AspectRatio(
                                    aspectRatio: 0.6,
                                    child: Center(child: CircularProgressIndicator()),
                                  )
                                : Image.memory(photo.thumb, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
                if (photo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(photo.summary,
                        textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 12),
                for (final m in _messages) _bubble(m),
                if (_thinking)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_thinkingNote ?? 'Reading the receipt… you can switch apps; I\'ll notify you.')),
                    ]),
                  ),
                if (draft == null && !_thinking)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 8, children: [
                      ActionChip(
                        avatar: const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('Read receipt'),
                        onPressed: () => _send(''),
                      ),
                    ]),
                  ),
                if (draft != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: ExpenseEditor(
                        draft: draft,
                        categories: _categories,
                        onChanged: () => setState(() {}),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: photo == null || _saving || _thinking ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving
                        ? 'Saving…'
                        : draft.needsReview
                            ? 'Save (needs review)'
                            : 'Save'),
                  ),
                ],
              ],
            ),
          ),
          // Message box.
          Material(
            elevation: 3,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + bottomInset),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_thinking,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: draft == null ? 'e.g. dinner at Ikea, shared with Des' : 'Correct something, e.g. "category is Family"',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _thinking ? null : () => _send(),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
