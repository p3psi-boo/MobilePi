import 'package:flutter/material.dart';

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.brandSeed,
    required this.appSurface,
    required this.appSurfaceLow,
    required this.appSurfaceLowest,
    required this.appText,
    required this.statusRunning,
    required this.statusWaiting,
    required this.statusIdle,
  });

  static const light = AppTokens(
    brandSeed: Color(0xFFD97757),
    appSurface: Color(0xFFF5F2EC),
    appSurfaceLow: Color(0xFFFAF8F2),
    appSurfaceLowest: Colors.white,
    appText: Color(0xFF2C2B26),
    statusRunning: Color(0xFF2F9E44),
    statusWaiting: Color(0xFFB7791F),
    statusIdle: Color(0xFF7A756B),
  );

  static const dark = AppTokens(
    brandSeed: Color(0xFFD97757),
    appSurface: Color(0xFF1A1815),
    appSurfaceLow: Color(0xFF22201D),
    appSurfaceLowest: Color(0xFF1F1D1A),
    appText: Color(0xFFEDEAE3),
    statusRunning: Color(0xFF69DB7C),
    statusWaiting: Color(0xFFFFD43B),
    statusIdle: Color(0xFFA8A29A),
  );

  final Color brandSeed;
  final Color appSurface;
  final Color appSurfaceLow;
  final Color appSurfaceLowest;
  final Color appText;
  final Color statusRunning;
  final Color statusWaiting;
  final Color statusIdle;

  Color statusForTask(String status, ColorScheme cs) => switch (status) {
    'running' => statusRunning,
    'waitingDecision' => statusWaiting,
    'error' => cs.error,
    'completed' => statusIdle.withValues(alpha: 0.65),
    _ => statusIdle,
  };

  @override
  AppTokens copyWith({
    Color? brandSeed,
    Color? appSurface,
    Color? appSurfaceLow,
    Color? appSurfaceLowest,
    Color? appText,
    Color? statusRunning,
    Color? statusWaiting,
    Color? statusIdle,
  }) {
    return AppTokens(
      brandSeed: brandSeed ?? this.brandSeed,
      appSurface: appSurface ?? this.appSurface,
      appSurfaceLow: appSurfaceLow ?? this.appSurfaceLow,
      appSurfaceLowest: appSurfaceLowest ?? this.appSurfaceLowest,
      appText: appText ?? this.appText,
      statusRunning: statusRunning ?? this.statusRunning,
      statusWaiting: statusWaiting ?? this.statusWaiting,
      statusIdle: statusIdle ?? this.statusIdle,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      brandSeed: Color.lerp(brandSeed, other.brandSeed, t)!,
      appSurface: Color.lerp(appSurface, other.appSurface, t)!,
      appSurfaceLow: Color.lerp(appSurfaceLow, other.appSurfaceLow, t)!,
      appSurfaceLowest: Color.lerp(
        appSurfaceLowest,
        other.appSurfaceLowest,
        t,
      )!,
      appText: Color.lerp(appText, other.appText, t)!,
      statusRunning: Color.lerp(statusRunning, other.statusRunning, t)!,
      statusWaiting: Color.lerp(statusWaiting, other.statusWaiting, t)!,
      statusIdle: Color.lerp(statusIdle, other.statusIdle, t)!,
    );
  }
}

extension AppTokensTheme on ThemeData {
  AppTokens get appTokens => extension<AppTokens>() ?? AppTokens.light;
}
