import 'dart:io';
import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_hub/server.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// MobilePi 中枢服务器入口
///
/// 核心职责：
/// - WebSocket 透明路由（Client ↔ Node）
/// - 设备路由表管理（内存级）
/// - Node 更新包 HTTP 文件服务
void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this help message.',
    )
    ..addOption(
      'host',
      abbr: 'o',
      help: 'The host/address to bind the Hub server to.',
      defaultsTo: '0.0.0.0',
    )
    ..addOption(
      'port',
      abbr: 'p',
      help: 'The port to bind the Hub server to.',
      defaultsTo: '8080',
    )
    ..addOption(
      'tenant-key',
      abbr: 't',
      help: 'The tenant key for authorization (defaults to MOBILE_PI_TENANT_KEY env var).',
    )
    ..addOption(
      'tenant-id',
      help: 'The tenant ID/key for authorization (alias for --tenant-key).',
    );

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (argResults['help'] as bool) {
    stdout.writeln('Usage: hub [options] [port] [tenantKey]');
    stdout.writeln('\nOptions:');
    stdout.writeln(parser.usage);
    stdout.writeln('\nExamples:');
    stdout.writeln('  # Bind to default IPv4 wildcard (0.0.0.0)');
    stdout.writeln('  hub --port 8080 --tenant-id secret');
    stdout.writeln('  # Bind to local IPv6 loopback (::1)');
    stdout.writeln('  hub --host ::1 --port 8080 --tenant-id secret');
    stdout.writeln('  # Bind to wildcard IPv6 (::) (enables dual-stack on most systems)');
    stdout.writeln('  hub --host :: --port 8080 --tenant-id secret');
    exit(0);
  }

  // Parse host option
  final host = argResults['host'] as String;

  // Support fallback to legacy positional arguments or environment variables
  int port = 8080;
  if (argResults.wasParsed('port')) {
    port = int.tryParse(argResults['port'] as String) ?? 8080;
  } else if (argResults.rest.isNotEmpty) {
    port = int.tryParse(argResults.rest.first) ?? 8080;
  }

  String? tenantKey = argResults['tenant-key'] as String? ?? argResults['tenant-id'] as String?;
  if (tenantKey == null || tenantKey.trim().isEmpty) {
    if (argResults.rest.length > 1) {
      tenantKey = argResults.rest[1];
    } else {
      tenantKey = Platform.environment['MOBILE_PI_TENANT_KEY'];
    }
  }

  if (tenantKey == null || tenantKey.trim().isEmpty) {
    stderr.writeln('Error: MOBILE_PI_TENANT_KEY / tenant-id is required.');
    stderr.writeln('Provide it via --tenant-key / --tenant-id option, the second positional argument, or MOBILE_PI_TENANT_KEY environment variable.');
    stderr.writeln('\nUsage: hub [options] [port] [tenantKey]');
    stderr.writeln('\nOptions:');
    stdout.writeln(parser.usage);
    exit(64);
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(formatLogRecord(record));
  });

  final server = HubServer(port: port, tenantKey: tenantKey, host: host);

  ProcessSignal.sigint.watch().listen((_) async {
    Logger('HubMain').info('signal=SIGINT action=shutdown');
    await server.shutdown();
    exit(0);
  });

  await server.start();
}

