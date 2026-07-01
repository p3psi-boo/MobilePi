import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  void Function(String taskId)? onNotificationTap;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final taskId = response.payload;
        if (taskId != null && taskId.isNotEmpty) {
          onNotificationTap?.call(taskId);
        }
      },
    );

    _initialized = true;
  }

  void showTaskNotification({
    required String taskId,
    required String title,
    required String body,
    bool isError = false,
  }) {
    if (!_initialized) return;

    final androidDetails = AndroidNotificationDetails(
      'mobilepi_tasks',
      '任务通知',
      channelDescription: '任务完成、失败或需要决策时的通知',
      importance: isError ? Importance.high : Importance.defaultImportance,
      priority: isError ? Priority.high : Priority.defaultPriority,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );

    _plugin.show(
      taskId.hashCode.abs() % 100000,
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: taskId,
    );
  }

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}
