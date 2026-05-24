import 'dart:io';
import 'package:logging/logging.dart';
import 'package:mobilepi_hub/server.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// MobilePi 中枢服务器入口
///
/// 核心职责：
/// - WebSocket 透明路由（Client ↔ Node）
/// - 设备路由表管理（内存级）
/// - Node 更新包 HTTP 文件服务
void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(formatLogRecord(record));
  });

  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8080 : 8080;
  final tenantKey = args.length > 1
      ? args[1]
      : Platform.environment['MOBILEPI_TENANT_KEY'];
  if (tenantKey == null || tenantKey.trim().isEmpty) {
    stderr.writeln('MOBILEPI_TENANT_KEY is required');
    exit(64);
  }
  final server = HubServer(port: port, tenantKey: tenantKey);

  ProcessSignal.sigint.watch().listen((_) async {
    Logger('HubMain').info('signal=SIGINT action=shutdown');
    await server.shutdown();
    exit(0);
  });

  await server.start();
}
