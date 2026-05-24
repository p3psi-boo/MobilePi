import 'dart:io';
import 'package:logging/logging.dart';
import 'package:mobilepi_node/daemon.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// MobilePi 物理机守护节点入口
///
/// Daemon 主动连接 Hub，Client 只通过 Hub 获取已注册 Daemon。
void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(formatLogRecord(record));
  });

  final firstArg = args.isNotEmpty ? args.first : null;
  final directPort = firstArg == null ? null : int.tryParse(firstArg);
  final hubUrl =
      firstArg ??
      Platform.environment['MOBILEPI_HUB_WS_URL'] ??
      'ws://localhost:8080/ws';
  final tenantKey = args.length > 1
      ? args[1]
      : Platform.environment['MOBILEPI_TENANT_KEY'];

  final daemon = directPort == null
      ? NodeDaemon(hubUrl: hubUrl, tenantKey: tenantKey)
      : NodeDaemon(port: directPort);

  ProcessSignal.sigint.watch().listen((_) async {
    Logger('NodeMain').info('signal=SIGINT action=shutdown');
    await daemon.stop();
    exit(0);
  });

  await daemon.start();
}
