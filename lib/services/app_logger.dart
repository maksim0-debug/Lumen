import 'dart:async';
import 'dart:developer' as developer;

import 'history_service.dart';

/// Severity levels for application logs.
enum AppLogLevel {
  debug(500, 'DEBUG'),
  info(800, 'INFO'),
  warning(900, 'WARN'),
  error(1000, 'ERROR');

  final int levelValue;
  final String label;

  const AppLogLevel(this.levelValue, this.label);
}

/// Centralized, high-performance structured logging service.
///
/// Features:
/// - Uses [developer.log] to integrate directly with DevTools and IDE consoles without UI blocking.
/// - Automatic asynchronous persistence of errors to [HistoryService] (SQLite app_logs).
/// - Non-blocking (fire-and-forget) DB operations with exception safety.
class AppLogger {
  AppLogger._();

  /// Optional listener hook for testing or external monitoring.
  static void Function(
    AppLogLevel level,
    String message,
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  )? onLog;

  /// Log a debug-level message.
  static void debug(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(
      AppLogLevel.debug,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      persistToHistory: false,
    );
  }

  /// Log an info-level message.
  static void info(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = false,
  }) {
    _log(
      AppLogLevel.info,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      persistToHistory: persistToHistory,
    );
  }

  /// Log a warning-level message.
  static void warning(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = false,
  }) {
    _log(
      AppLogLevel.warning,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      persistToHistory: persistToHistory,
    );
  }

  /// Log an error-level message. Automatically persisted to [HistoryService] by default.
  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = true,
  }) {
    _log(
      AppLogLevel.error,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      persistToHistory: persistToHistory,
    );
  }

  /// Short alias for [debug].
  static void d(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      debug(message, tag: tag, error: error, stackTrace: stackTrace);

  /// Short alias for [info].
  static void i(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = false,
  }) =>
      info(
        message,
        tag: tag,
        error: error,
        stackTrace: stackTrace,
        persistToHistory: persistToHistory,
      );

  /// Short alias for [warning].
  static void w(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = false,
  }) =>
      warning(
        message,
        tag: tag,
        error: error,
        stackTrace: stackTrace,
        persistToHistory: persistToHistory,
      );

  /// Short alias for [error].
  static void e(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool persistToHistory = true,
  }) =>
      AppLogger.error(
        message,
        tag: tag,
        error: error,
        stackTrace: stackTrace,
        persistToHistory: persistToHistory,
      );

  /// Generic log method with configurable level and persistence.
  static void log(
    String message, {
    AppLogLevel level = AppLogLevel.info,
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool? persistToHistory,
  }) {
    final shouldPersist = persistToHistory ?? (level == AppLogLevel.error);
    _log(
      level,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      persistToHistory: shouldPersist,
    );
  }

  static void _log(
    AppLogLevel level,
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    required bool persistToHistory,
  }) {
    final effectiveTag = tag ?? 'App';

    // 1. Output to developer.log (safe, non-blocking, integrated with DevTools)
    developer.log(
      message,
      name: effectiveTag,
      level: level.levelValue,
      error: error,
      stackTrace: stackTrace,
      time: DateTime.now(),
    );

    // 2. Notify optional listener
    if (onLog != null) {
      try {
        onLog!(level, message, tag, error, stackTrace);
      } catch (_) {}
    }

    // 3. Persist to HistoryService asynchronously if requested
    if (persistToHistory) {
      _persistLogAsync(effectiveTag, level, message, error);
    }
  }

  static void _persistLogAsync(
    String tag,
    AppLogLevel level,
    String message,
    Object? error,
  ) {
    try {
      final formattedMessage =
          error != null ? '[$tag] $message (Error: $error)' : '[$tag] $message';

      unawaited(
        HistoryService()
            .insertRawLog(
              formattedMessage,
              level: level.label,
            )
            .catchError((_) {}),
      );
    } catch (_) {
      // Never crash the application if logging persistence fails
    }
  }
}
