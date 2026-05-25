import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/node_provider.dart';
import '../services/websocket_service.dart';

/// 设置页 —— Hub 连接信息。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _controller;
  late final TextEditingController _keyController;
  String? _urlError;
  String? _keyError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final current = context.read<NodeProvider>().hubUrl;
    _controller = TextEditingController(text: current);
    _keyController = TextEditingController(
      text: context.read<NodeProvider>().tenantKey,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _controller.text.trim();
    final rawKey = _keyController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _urlError = 'URL 不能为空';
        _keyError = null;
      });
      return;
    }
    if (rawKey.isEmpty) {
      setState(() {
        _urlError = null;
        _keyError = 'Key 不能为空';
      });
      return;
    }
    try {
      WebSocketService.normalizeHubUrl(raw);
    } on FormatException catch (e) {
      setState(() {
        _urlError = e.message;
        _keyError = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _urlError = null;
      _keyError = null;
    });
    try {
      await context.read<NodeProvider>().setHubConnection(
        url: raw,
        tenantKey: rawKey,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已保存，正在连接…'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _urlError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetDefault() {
    _controller.text = WebSocketService.defaultHubUrl();
    _keyController.text = WebSocketService.defaultTenantKey();
    setState(() {
      _urlError = null;
      _keyError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final currentUrl = context.select<NodeProvider, String>((p) => p.hubUrl);
    final currentKey = context.select<NodeProvider, String>((p) => p.tenantKey);
    final isConnecting = context.select<NodeProvider, bool>((p) => p.isConnecting);
    final isConnected = context.select<NodeProvider, bool>((p) => p.isConnected);
    final hasTenantKey = context.select<NodeProvider, bool>((p) => p.hasTenantKey);
    final defaultUrl = WebSocketService.defaultHubUrl();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const _SectionLabel('Hub 连接'),
          const SizedBox(height: 6),
          Text(
            '客户端会携带租户 Key 连接 Hub，并只接收同一 Key 下的 Node 状态。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_saving,
            autocorrect: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Hub URL',
              hintText: defaultUrl,
              errorText: _urlError,
              filled: true,
              fillColor: cs.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: cs.primary, width: 1.2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyController,
            enabled: !_saving,
            autocorrect: false,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '租户 Key',
              hintText: '自定义 Key',
              errorText: _keyError,
              filled: true,
              fillColor: cs.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: cs.primary, width: 1.2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _saving ? null : _resetDefault,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('重置为默认'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: const Text('保存并连接'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _ConnectionStatusRow(
            isConnecting: isConnecting,
            isConnected: isConnected,
            hasTenantKey: hasTenantKey,
          ),
          _InfoRow(label: '当前已配置 URL', value: currentUrl),
          _InfoRow(label: '当前 Key', value: _maskKey(currentKey)),
          _InfoRow(label: '默认 URL', value: defaultUrl),
        ],
      ),
    );
  }
}

String _maskKey(String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) return '未设置';
  if (trimmed.length <= 4) return '••••';
  return '${trimmed.substring(0, 2)}••••${trimmed.substring(trimmed.length - 2)}';
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: cs.onSurface.withValues(alpha: 0.65),
      ),
    );
  }
}

class _ConnectionStatusRow extends StatelessWidget {
  final bool isConnecting;
  final bool isConnected;
  final bool hasTenantKey;

  const _ConnectionStatusRow({
    required this.isConnecting,
    required this.isConnected,
    required this.hasTenantKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    IconData icon;
    String text;
    Color color;

    if (!hasTenantKey) {
      icon = Icons.key_off_rounded;
      text = '未连接（未设置 Key）';
      color = cs.error;
    } else if (isConnecting) {
      icon = Icons.sync_rounded;
      text = '连接中';
      color = cs.secondary;
    } else if (isConnected) {
      icon = Icons.check_circle_rounded;
      text = '已连接';
      color = cs.primary;
    } else {
      icon = Icons.error_outline_rounded;
      text = '未连接';
      color = cs.error;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            '连接状态：$text',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
