import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import 'providers/node_provider.dart';
import 'screens/dashboard_screen.dart';

/// MobilePi 客户端根组件
///
/// 视觉灵感来自 Claude Mobile：
/// - 暖色奶油 / 珊瑚色调，弱化“紫色 Material”默认观感
/// - 极柔和的卡片边框 + 圆角，强调留白
/// - 顶部 AppBar 与 Surface 颜色融为一体，去掉阴影
class MobilePiApp extends StatelessWidget {
  const MobilePiApp({super.key});

  // Claude-style 调色板
  static const _seed = Color(0xFFD97757); // 暖珊瑚色（Claude 主品牌色）

  static const _lightBg = Color(0xFFF5F2EC); // 暖奶油背景
  static const _lightSurface = Color(0xFFFAF8F2); // 卡片底
  static const _lightText = Color(0xFF2C2B26); // 主文本

  static const _darkBg = Color(0xFF1A1815); // 深木色背景
  static const _darkSurface = Color(0xFF22201D); // 卡片底
  static const _darkText = Color(0xFFEDEAE3);

  @override
  Widget build(BuildContext context) {
    final lightColorScheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ).copyWith(
          surface: _lightBg,
          surfaceContainerLow: _lightSurface,
          surfaceContainerLowest: Colors.white,
          onSurface: _lightText,
        );

    final darkColorScheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ).copyWith(
          surface: _darkBg,
          surfaceContainerLow: _darkSurface,
          surfaceContainerLowest: const Color(0xFF1F1D1A),
          onSurface: _darkText,
        );

    return ChangeNotifierProvider(
      create: (_) => NodeProvider(),
      child: MaterialApp(
        title: 'MobilePi',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(lightColorScheme, Brightness.light),
        darkTheme: _buildTheme(darkColorScheme, Brightness.dark),
        home: const _AppLifecycleReconnector(child: DashboardScreen()),
      ),
    );
  }

  ThemeData _buildTheme(ColorScheme cs, Brightness brightness) {
    final cardTheme = CardThemeData(
      elevation: 0,
      color: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
    );

    const listTileTheme = ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 10,
      horizontalTitleGap: 12,
    );

    final appBarTheme = AppBarTheme(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: cs.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    );

    return ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      scaffoldBackgroundColor: cs.surface,
      fontFamily: 'system-ui',
      fontFamilyFallback: const [
        'PingFang SC',
        'Heiti SC',
        'Microsoft YaHei',
        'sans-serif',
      ],
      cardTheme: cardTheme,
      listTileTheme: listTileTheme,
      appBarTheme: appBarTheme,
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant.withValues(alpha: 0.4),
        thickness: 0.6,
        space: 0,
      ),
      splashFactory: InkSparkle.splashFactory,
      extensions: [_buildMarkdownTheme(cs, brightness)],
    );
  }

  /// Pi-tui 风格 markdown 主题（保留原逻辑）
  GptMarkdownThemeData _buildMarkdownTheme(
    ColorScheme cs,
    Brightness brightness,
  ) {
    final headingColor = cs.secondary.withValues(alpha: 0.92);
    final base = TextStyle(
      color: headingColor,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    return GptMarkdownThemeData(
      brightness: brightness,
      h1: base.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
      h2: base.copyWith(fontSize: 19),
      h3: base.copyWith(fontSize: 17),
      h4: base.copyWith(fontSize: 15),
      h5: base.copyWith(fontSize: 14),
      h6: base.copyWith(
        fontSize: 13,
        color: cs.onSurface.withValues(alpha: 0.78),
      ),
      autoAddDividerLineAfterH1: false,
      linkColor: cs.primary.withValues(alpha: 0.85),
      linkHoverColor: cs.secondary.withValues(alpha: 0.9),
      hrLineColor: cs.outlineVariant,
      hrLineThickness: 0.6,
      highlightColor: cs.surfaceContainerHighest.withAlpha(50),
    );
  }
}

/// 监听 app 前后台生命周期：从后台切回前台（resumed）时强制重连 + 差量同步，
/// 满足 SPEC「切回前台时快速差量同步」的要求，避免干等退避定时器。
class _AppLifecycleReconnector extends StatefulWidget {
  const _AppLifecycleReconnector({required this.child});

  final Widget child;

  @override
  State<_AppLifecycleReconnector> createState() =>
      _AppLifecycleReconnectorState();
}

class _AppLifecycleReconnectorState extends State<_AppLifecycleReconnector>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<NodeProvider>().onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
