import 'dart:io';
import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_node/daemon.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// MobilePi 物理机守护节点入口
///
/// Daemon 主动连接 Hub，Client 只通过 Hub 获取已注册 Daemon。
void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this help message.',
    )
    ..addOption(
      'port',
      abbr: 'p',
      help: 'Start a direct local WebSocket server on the specified port instead of connecting to a Hub.',
    )
    ..addOption(
      'hub-url',
      abbr: 'u',
      help: 'The WebSocket URL of the Hub to connect to (defaults to MOBILE_PI_HUB_WS_URL env var or ws://localhost:8080/ws).',
    )
    ..addOption(
      'tenant-key',
      abbr: 't',
      help: 'The tenant key to authenticate with the Hub (defaults to MOBILE_PI_TENANT_KEY env var).',
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
    stdout.writeln('Usage: daemon [options] [hubUrl/port] [tenantKey]');
    stdout.writeln('\nOptions:');
    stdout.writeln(parser.usage);
    stdout.writeln('\nExamples:');
    stdout.writeln('  # Connect to Hub (default)');
    stdout.writeln('  daemon --hub-url ws://localhost:8080/ws --tenant-key secret');
    stdout.writeln('  # Run in direct server mode');
    stdout.writeln('  daemon --port 9000');
    exit(0);
  }

  int? directPort;
  String? hubUrl;
  String? tenantKey;

  // Determine mode (direct port vs Hub client)
  if (argResults.wasParsed('port')) {
    directPort = int.tryParse(argResults['port'] as String);
    if (directPort == null) {
      stderr.writeln('Error: Invalid port number "${argResults['port']}".');
      exit(64);
    }
  }

  if (directPort == null) {
    // Check if port is specified as a positional argument
    final firstArg = argResults.rest.isNotEmpty ? argResults.rest.first : null;
    final firstArgAsPort = firstArg == null ? null : int.tryParse(firstArg);

    if (firstArgAsPort != null) {
      directPort = firstArgAsPort;
    } else {
      // Connecting to Hub
      hubUrl = argResults['hub-url'] as String?;
      if (hubUrl == null || hubUrl.trim().isEmpty) {
        hubUrl = firstArg ??
            Platform.environment['MOBILE_PI_HUB_WS_URL'] ??
            'ws://localhost:8080/ws';
      }

      tenantKey = argResults['tenant-key'] as String?;
      if (tenantKey == null || tenantKey.trim().isEmpty) {
        if (argResults.rest.length > 1) {
          tenantKey = argResults.rest[1];
        } else {
          tenantKey = Platform.environment['MOBILE_PI_TENANT_KEY'];
        }
      }
    }
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(formatLogRecord(record));
  });

  final NodeDaemon daemon;
  if (directPort != null) {
    daemon = NodeDaemon(port: directPort);
  } else {
    daemon = NodeDaemon(hubUrl: hubUrl, tenantKey: tenantKey);
  }

  ProcessSignal.sigint.watch().listen((_) async {
    Logger('NodeMain').info('signal=SIGINT action=shutdown');
    await daemon.stop();
    exit(0);
  });

  ProcessSignal.sigterm.watch().listen((_) async {
    Logger('NodeMain').info('event=node.sigterm_received shutting_down');
    await daemon.stop();
    exit(0);
  });

  await daemon.start();
}

