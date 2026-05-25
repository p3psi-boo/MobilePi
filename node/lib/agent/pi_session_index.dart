import 'dart:convert';
import 'dart:io';

import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:path/path.dart' as p;

import 'pi_capabilities.dart';

/// Filesystem-backed Pi session index.
///
/// Pi's RPC exposes the active session, but Pi's own session selector lists
/// recent sessions by scanning `~/.pi/agent/sessions/<encoded-cwd>/*.jsonl`.
class PiSessionIndex {
  final String cwd;
  final String agentDir;

  PiSessionIndex({String? cwd, String? agentDir})
    : cwd = cwd ?? Directory.current.path,
      agentDir = agentDir ?? defaultAgentDir();

  static String defaultAgentDir() {
    final envDir = Platform.environment['PI_CODING_AGENT_DIR'];
    if (envDir != null && envDir.trim().isNotEmpty) {
      return _expandHome(envDir.trim());
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return p.join('.pi', 'agent');
    return p.join(home, '.pi', 'agent');
  }

  static String defaultSessionDir(String cwd, {String? agentDir}) {
    final safePath =
        '--${cwd.replaceFirst(RegExp(r'^[\/\\]'), '').replaceAll(RegExp(r'[\/\\:]'), '-')}--';
    return p.join(agentDir ?? defaultAgentDir(), 'sessions', safePath);
  }

  Future<List<PiSessionInfo>> list({int limit = 20}) async {
    final dir = Directory(defaultSessionDir(cwd, agentDir: agentDir));
    if (!await dir.exists()) return <PiSessionInfo>[];

    final sessions = await _listSessionsFromFiles(
      await _jsonlFilesInDirectory(dir),
    );
    return _sortAndLimit(sessions, limit);
  }

  Future<List<PiSessionInfo>> listAll({
    int limit = 20,
    String? activeSessionPath,
  }) async {
    final sessionsDir = Directory(p.join(agentDir, 'sessions'));
    if (!await sessionsDir.exists()) return <PiSessionInfo>[];

    final files = <File>[];
    await for (final entity in sessionsDir.list()) {
      if (entity is! Directory) continue;
      files.addAll(await _jsonlFilesInDirectory(entity));
    }

    final sessions = await _listSessionsFromFiles(
      files,
      activeSessionPath: activeSessionPath,
    );
    return _sortAndLimit(sessions, limit);
  }

  static Future<List<File>> _jsonlFilesInDirectory(Directory dir) async {
    return dir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
  }

  static Future<List<PiSessionInfo>> _listSessionsFromFiles(
    List<File> files, {
    String? activeSessionPath,
  }) async {
    final sessions = <PiSessionInfo>[];
    for (final file in files) {
      final isActive =
          activeSessionPath != null &&
          activeSessionPath.isNotEmpty &&
          file.path == activeSessionPath;
      final info = await buildSessionInfo(file, includeMessages: isActive);
      if (info != null) sessions.add(info);
    }
    return sessions;
  }

  static List<PiSessionInfo> _sortAndLimit(
    List<PiSessionInfo> sessions,
    int limit,
  ) {
    sessions.sort((a, b) {
      final aTime =
          a.modified ?? a.created ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          b.modified ?? b.created ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return List.unmodifiable(sessions.take(limit));
  }

  static Future<Map<String, dynamic>?> getSessionMessages({
    required String sessionPath,
    int limit = 20,
    int? beforeIndex,
  }) async {
    try {
      final file = File(sessionPath);
      if (!await file.exists()) return null;

      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        return {
          'messages': <Map<String, dynamic>>[],
          'totalCount': 0,
          'nextBeforeIndex': 0,
        };
      }

      final messageLines = <String>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.contains('"type":"message"')) {
          messageLines.add(line);
        }
      }

      final totalCount = messageLines.length;
      final actualBeforeIndex = beforeIndex ?? totalCount;
      final start = (actualBeforeIndex - limit).clamp(0, totalCount);
      final end = actualBeforeIndex.clamp(0, totalCount);

      final messages = <PiSessionMessageInfo>[];
      if (start < end) {
        final slice = messageLines.sublist(start, end);
        for (final line in slice) {
          try {
            final entry = jsonDecode(line);
            if (entry is! Map || entry['type'] != 'message') continue;
            final entryMap = Map<String, dynamic>.from(entry);

            final rawMessage = entryMap['message'];
            if (rawMessage is! Map) continue;
            final message = Map<String, dynamic>.from(rawMessage);
            final role = message['role']?.toString();

            final contentBlocks = _extractContentBlocks(message);
            final text = role == 'toolResult'
                ? _toolResultToMarkdown(message, contentBlocks)
                : _blocksToMarkdown(contentBlocks);

            if (text.isNotEmpty) {
              final timestamp = _messageTimestampMs(message, entryMap);
              messages.add(
                PiSessionMessageInfo(
                  role: role ?? '',
                  text: text,
                  timestamp: timestamp == null
                      ? null
                      : DateTime.fromMillisecondsSinceEpoch(
                          timestamp,
                          isUtc: true,
                        ),
                  model: message['model']?.toString(),
                  usage: message['usage'] is Map
                      ? UsageInfo.fromJson(
                          Map<String, dynamic>.from(message['usage'] as Map),
                        )
                      : null,
                ),
              );
            }
          } catch (_) {}
        }
      }

      return {
        'messages': messages.map((m) => m.toJson()).toList(),
        'totalCount': totalCount,
        'nextBeforeIndex': start,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<PiSessionInfo?> buildSessionInfo(
    File file, {
    bool includeMessages = false,
  }) async {
    try {
      final lines = await file.readAsLines();
      if (lines.isEmpty) return null;

      // Find first non-empty line (header)
      Map<String, dynamic>? header;
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map && decoded['type'] == 'session') {
            header = Map<String, dynamic>.from(decoded);
            break;
          }
        } catch (_) {}
      }
      if (header == null) return null;
      final id = header['id']?.toString();
      if (id == null || id.isEmpty) return null;

      final stat = await file.stat();
      var messageCount = 0;
      var firstMessage = '';
      final messages = <PiSessionMessageInfo>[];
      String? name;
      int? lastActivityMs;

      // Scan lines for name, messageCount, firstMessage, and lastActivity
      for (final line in lines) {
        if (line.trim().isEmpty) continue;

        final isMessage = line.contains('"type":"message"');
        final isSessionInfo = line.contains('"type":"session_info"');

        if (!isMessage && !isSessionInfo) continue;

        try {
          final entry = jsonDecode(line);
          if (entry is! Map) continue;
          final entryMap = Map<String, dynamic>.from(entry);

          if (entryMap['type'] == 'session_info') {
            final value = entryMap['name']?.toString().trim();
            name = value == null || value.isEmpty ? null : value;
            continue;
          }

          if (entryMap['type'] == 'message') {
            messageCount++;

            final rawMessage = entryMap['message'];
            if (rawMessage is! Map) continue;
            final message = Map<String, dynamic>.from(rawMessage);
            final role = message['role']?.toString();

            final timestamp = _messageTimestampMs(message, entryMap);
            if (timestamp != null) {
              lastActivityMs = lastActivityMs == null
                  ? timestamp
                  : (timestamp > lastActivityMs ? timestamp : lastActivityMs);
            }

            if (includeMessages || (role == 'user' && firstMessage.isEmpty)) {
              final contentBlocks = _extractContentBlocks(message);
              final text = role == 'toolResult'
                  ? _toolResultToMarkdown(message, contentBlocks)
                  : _blocksToMarkdown(contentBlocks);

              if (text.isNotEmpty) {
                if (includeMessages) {
                  messages.add(
                    PiSessionMessageInfo(
                      role: role ?? '',
                      text: text,
                      timestamp: timestamp == null
                          ? null
                          : DateTime.fromMillisecondsSinceEpoch(
                              timestamp,
                              isUtc: true,
                            ),
                      model: message['model']?.toString(),
                      usage: message['usage'] is Map
                          ? UsageInfo.fromJson(
                              Map<String, dynamic>.from(message['usage'] as Map),
                            )
                          : null,
                    ),
                  );
                }
                if (role == 'user' && firstMessage.isEmpty) {
                  firstMessage = _extractTextOnly(contentBlocks).trim();
                }
              }
            }
          }
        } catch (_) {}
      }

      final created = _parseIsoDate(header['timestamp']);
      final modified = lastActivityMs == null
          ? created ?? stat.modified
          : DateTime.fromMillisecondsSinceEpoch(lastActivityMs, isUtc: true);

      return PiSessionInfo(
        path: file.path,
        id: id,
        cwd: header['cwd']?.toString() ?? '',
        name: name,
        parentSessionPath: header['parentSession']?.toString(),
        created: created,
        modified: modified,
        messageCount: messageCount,
        firstMessage: firstMessage.isEmpty ? '(no messages)' : firstMessage,
        messages: messages,
      );
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _extractContentBlocks(
    Map<String, dynamic> message,
  ) {
    final content = message['content'];
    if (content is String) {
      return [
        {'type': 'text', 'text': content},
      ];
    }
    if (content is! List) return const [];

    return content.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  static String _toolResultToMarkdown(
    Map<String, dynamic> message,
    List<Map<String, dynamic>> blocks,
  ) {
    final toolName = message['toolName']?.toString() ?? 'unknown';
    final isError = message['isError'] == true;
    final text = blocks
        .where((b) => b['type'] == 'text')
        .map((b) => b['text']?.toString() ?? '')
        .join('\n')
        .trim();

    final status = isError ? '失败' : '成功';
    return '<tool_result name="$toolName" status="$status">\n$text\n</tool_result>';
  }

  static String _blocksToMarkdown(List<Map<String, dynamic>> blocks) {
    final parts = <String>[];
    for (final block in blocks) {
      final type = block['type'];
      if (type == 'text') {
        final text = block['text']?.toString();
        if (text != null) parts.add(text);
      } else if (type == 'thinking') {
        final thinking = block['thinking']?.toString();
        if (thinking != null) {
          parts.add('<thinking>\n$thinking\n</thinking>');
        }
      } else if (type == 'toolCall') {
        final name = block['name']?.toString() ?? 'unknown';
        parts.add('[工具: $name]');
      }
    }
    return parts.join('\n\n').trim();
  }

  static String _extractTextOnly(List<Map<String, dynamic>> blocks) {
    return blocks
        .where((b) => b['type'] == 'text')
        .map((b) => b['text']?.toString() ?? '')
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int? _messageTimestampMs(
    Map<String, dynamic> message,
    Map<String, dynamic> entry,
  ) {
    final timestamp = message['timestamp'];
    if (timestamp is int) return timestamp;
    if (timestamp is num) return timestamp.toInt();
    return _parseIsoDate(entry['timestamp'])?.millisecondsSinceEpoch;
  }

  static DateTime? _parseIsoDate(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _expandHome(String path) {
    if (path == '~') return Platform.environment['HOME'] ?? path;
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return path;
      return p.join(home, path.substring(2));
    }
    return path;
  }
}
