import 'preferences_helper.dart';

enum AndroidDiagnosticMode { off, compact, verbose }

/// Reload once per operation so headless engines see changes made by the UI.
class AndroidDiagnosticSettings {
  static const verboseUntilKey = 'android_diagnostics_verbose_until_ms';
  static const verboseDuration = Duration(hours: 2);

  static AndroidDiagnosticMode resolve({
    required bool loggingEnabled,
    required int verboseUntilMs,
    required int nowMs,
  }) {
    if (!loggingEnabled) return AndroidDiagnosticMode.off;
    return verboseUntilMs > nowMs &&
            verboseUntilMs <= nowMs + verboseDuration.inMilliseconds
        ? AndroidDiagnosticMode.verbose
        : AndroidDiagnosticMode.compact;
  }

  static Future<AndroidDiagnosticMode> read() async {
    final prefs = await PreferencesHelper.getSafeInstance();
    await prefs.reload();
    return resolve(
      loggingEnabled: prefs.getBool('enable_logging') ?? true,
      verboseUntilMs: prefs.getInt(verboseUntilKey) ?? 0,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<void> setVerbose(bool enabled) async {
    final prefs = await PreferencesHelper.getSafeInstance();
    final until = enabled
        ? DateTime.now().add(verboseDuration).millisecondsSinceEpoch
        : 0;
    if (!await prefs.setInt(verboseUntilKey, until)) {
      throw StateError('Cannot persist Android diagnostic mode');
    }
  }
}
