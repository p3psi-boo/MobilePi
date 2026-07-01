import 'package:flutter/material.dart';
import 'app.dart';
import 'services/log_buffer.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LogBuffer.instance.attach();
  await NotificationService.instance.init();
  runApp(const MobilePiApp());
}
