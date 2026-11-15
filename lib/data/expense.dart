import 'dart:convert';

enum UploadState { pending, uploaded, failed, none }

/// One transaction. Fields mirror the ledger's Expenses tab.
class Expense {
  Expense({
    required this.id,
    this.date,
    this.description = '',
    this.merchant,
    this.category,
    this.amount,
    this.currency = 'SGD',
    this.amountSgd,
    this.myShare,
    List<String>? who,
    this.split,
    this.paidWith,
    this.status = 'Needs review',
    List<String>? inferred,
    this.driveFileId,
    this.driveLink,
    this.fileName,
    this.localPath,
    this.thumbPath,
    this.uploadState = UploadState.none,
    this.uploadError,
    this.photoBytes,
    this.notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : who = who ?? const ['Self'],
        inferred = inferred ?? const [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// yyyy-MM-dd, or null for "Missing date".
  String? date;
  String description;
  String? merchant;
  String? category;
  double? amount;
  String currency;
  double? amountSgd;
  double? myShare;
  List<String> who;
  String? split;
  String? paidWith;

  /// "Needs review" or "Reviewed".
  String status;
  List<String> inferred;
  String? driveFileId;
  String? driveLink;
  String? fileName;
  String? localPath;
  String? thumbPath;
  UploadState uploadState;
  String? uploadError;
  int? photoBytes;
  String? notes;
  DateTime createdAt;
  DateTime updatedAt;

  bool get hasPhoto => driveFileId != null || localPath != null;

  DateTime? get dateValue => date == null ? null : DateTime.tryParse(date!);

  Map<String, Object?> toMap() => {
        'id': id,
        'date': date,
        'description': description,
        'merchant': merchant,
        'category': category,
        'amount': amount,
        'currency': currency,
        'amount_sgd': amountSgd,
        'my_share': myShare,
        'who': jsonEncode(who),
        'split': split,
        'paid_with': paidWith,
        'status': status,
        'inferred': jsonEncode(inferred),
        'drive_file_id': driveFileId,
        'drive_link': driveLink,
        'file_name': fileName,
        'local_path': localPath,
        'thumb_path': thumbPath,
        'upload_state': uploadState.name,
        'upload_error': uploadError,
        'photo_bytes': photoBytes,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static List<String> _list(Object? v) {
    if (v == null) return const [];
    try {
      return (jsonDecode(v as String) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  factory Expense.fromMap(Map<String, Object?> m) => Expense(
        id: m['id'] as String,
        date: m['date'] as String?,
        description: (m['description'] as String?) ?? '',
        merchant: m['merchant'] as String?,
        category: m['category'] as String?,
        amount: (m['amount'] as num?)?.toDouble(),
        currency: (m['currency'] as String?) ?? 'SGD',
        amountSgd: (m['amount_sgd'] as num?)?.toDouble(),
        myShare: (m['my_share'] as num?)?.toDouble(),
        who: _list(m['who']),
        split: m['split'] as String?,
        paidWith: m['paid_with'] as String?,
        status: (m['status'] as String?) ?? 'Needs review',
        inferred: _list(m['inferred']),
        driveFileId: m['drive_file_id'] as String?,
        driveLink: m['drive_link'] as String?,
        fileName: m['file_name'] as String?,
        localPath: m['local_path'] as String?,
        thumbPath: m['thumb_path'] as String?,
        uploadState: UploadState.values.firstWhere(
          (s) => s.name == m['upload_state'],
          orElse: () => UploadState.none,
        ),
        uploadError: m['upload_error'] as String?,
        photoBytes: m['photo_bytes'] as int?,
        notes: m['notes'] as String?,
        createdAt: DateTime.tryParse((m['created_at'] as String?) ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse((m['updated_at'] as String?) ?? '') ?? DateTime.now(),
      );
}
