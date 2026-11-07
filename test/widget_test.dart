import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_tracker/config.dart';

void main() {
  test('config has dashboard IDs', () {
    expect(AppConfig.ledgerSpreadsheetId, isNotEmpty);
    expect(AppConfig.receiptsFolderId, isNotEmpty);
  });
}
