/// Fixed IDs for the Life Dashboard (dashboard account: mayerloh@gmail.com).
class AppConfig {
  /// Life Dashboard ledger (Google Sheet).
  static const ledgerSpreadsheetId =
      '18eGCZ84pzhND5VGr_vq9B2b4xqylIf5AG3AEsPmk5do';

  /// Drive folder: Life Dashboard / Receipts.
  static const receiptsFolderId = '10Vw7l3lEzJeg9mo2Op-LkO5tKxEKxpDk';

  /// "Web application" OAuth client ID from the Google Cloud project.
  /// Android sign-in needs it as the server client ID. Filled in after setup.
  static const webClientId =
      '4896366558-r7su3se43fi58jrjob0jokth4ete9j09.apps.googleusercontent.com';

  /// Default Gemini model; can be changed in Settings.
  static const defaultGeminiModel = 'gemini-flash-latest';
}
