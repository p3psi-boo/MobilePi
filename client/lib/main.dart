import 'package:flutter/material.dart';
import 'app.dart';
import 'services/log_buffer.dart';

void main() {
  // 把日志收到 buffer 里，方便日志页查看
  LogBuffer.instance.attach();
  runApp(const MobilePiApp());
}
