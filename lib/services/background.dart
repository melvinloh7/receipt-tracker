import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Reports progress from a background job: a line of text and, optionally,
/// how far along it is (e.g. 3 of 5).
typedef ProgressReporter = void Function(String text, {int? done, int? total});

/// Runs work so it keeps going when you switch apps or lock the phone.
///
/// While a job runs, Android shows a quiet "in progress" notification (an
/// Android foreground service), which stops the system cutting the app's
/// network. When the job finishes and the app isn't on screen, a normal
/// notification says how it went.
class Background {
  Background._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _progressId = 1001;

  /// Jobs running now. The service starts with the first and stops with the
  /// last, so overlapping jobs (an upload and an AI read) keep each other alive.
  static int _active = 0;
  static int _doneId = 2000;

  static const _progressChannel = AndroidNotificationDetails(
    'work_in_progress',
    'Work in progress',
    channelDescription: 'Shown while receipts upload or the AI reads them.',
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    onlyAlertOnce: true,
    showWhen: false,
  );

  static const _doneChannel = AndroidNotificationDetails(
    'work_done',
    'Finished',
    channelDescription: 'Tells you when background work has finished.',
    importance: Importance.high,
    priority: Priority.high,
  );

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _ready = true;
  }

  /// Asks for notification permission (Android 13+). Safe to call repeatedly.
  static Future<bool> ensurePermission() async {
    await init();
    return await _android?.requestNotificationsPermission() ?? true;
  }

  static bool get _appOnScreen =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  static AndroidNotificationDetails _progressDetails(int? done, int? total) {
    if (done == null || total == null || total <= 0) return _progressChannel;
    return AndroidNotificationDetails(
      _progressChannel.channelId,
      _progressChannel.channelName,
      channelDescription: _progressChannel.channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
      showWhen: false,
      showProgress: true,
      maxProgress: total,
      progress: done,
    );
  }

  /// Runs [job] in the background-safe way described above.
  ///
  /// [title] names the work in the progress notification. [summary] turns the
  /// result into the finished notification's title and body; [failure] does
  /// the same for an error. The job's result (or error) is passed back to the
  /// caller as usual, so the screen can show it too.
  static Future<T> run<T>({
    required String title,
    required Future<T> Function(ProgressReporter report) job,
    required (String, String) Function(T result) summary,
    (String, String) Function(Object error)? failure,
  }) async {
    await init();
    var serviceStarted = false;
    _active++;
    try {
      await _android?.startForegroundService(
        id: _progressId,
        title: title,
        body: 'Starting…',
        notificationDetails: _progressChannel,
        foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeDataSync},
      );
      serviceStarted = true;
    } catch (_) {
      // No permission or the service couldn't start: run anyway. It works
      // while the app stays on screen.
    }

    void report(String text, {int? done, int? total}) {
      if (!serviceStarted) return;
      _plugin
          .show(
            id: _progressId,
            title: title,
            body: text,
            notificationDetails: NotificationDetails(android: _progressDetails(done, total)),
          )
          .ignore();
    }

    try {
      final result = await job(report);
      await _finish(serviceStarted, summary(result));
      return result;
    } catch (e) {
      final (t, b) = failure?.call(e) ?? ('$title failed', e.toString());
      await _finish(serviceStarted, (t, b));
      rethrow;
    }
  }

  static Future<void> _finish(bool serviceStarted, (String, String) message) async {
    _active--;
    if (serviceStarted && _active <= 0) {
      _active = 0;
      try {
        await _android?.stopForegroundService();
      } catch (_) {}
    }
    // Only alert when you're elsewhere; on screen, the app shows the result.
    if (_appOnScreen) return;
    final (title, body) = message;
    await _plugin.show(
      id: _doneId++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(android: _doneChannel),
    );
  }
}
