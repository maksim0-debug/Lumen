import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' show join;
import 'app_logger.dart';

class PreferencesHelper {
  /// Otrimaty ekzemplyar SharedPreferences bezpechno.
  /// Yakshcho fayl poshkodzhenyi (FormatException), vin bude vydalenyj,
  /// i povernetsya novyj chystyj ekzemplyar.
  static Future<SharedPreferences> getSafeInstance() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      AppLogger.w(
        "Error loading SharedPreferences: $e",
        tag: 'PreferencesHelper',
      );
      if (e.toString().contains("FormatException") ||
          e.toString().contains("Unexpected character")) {
        AppLogger.w(
          "Detected corruption. Attempting to repair...",
          tag: 'PreferencesHelper',
        );
        await _deletePreferencesFile();

        // Try again after deletion
        try {
          return await SharedPreferences.getInstance();
        } catch (e2) {
          AppLogger.e(
            "Failed to recover SharedPreferences",
            tag: 'PreferencesHelper',
            error: e2,
            persistToHistory: false,
          );
          // Rethrow or return a mock/empty if feasible?
          // For now, rethrow because app might depend on it.
          rethrow;
        }
      }
      rethrow;
    }
  }

  static Future<void> _deletePreferencesFile() async {
    try {
      if (Platform.isWindows || Platform.isLinux) {
        final supportDir = await getApplicationSupportDirectory();
        final prefsFile =
            File(join(supportDir.path, 'shared_preferences.json'));

        if (await prefsFile.exists()) {
          await prefsFile.delete();
          AppLogger.i(
            "Deleted corrupted preferences file at: ${prefsFile.path}",
            tag: 'PreferencesHelper',
          );
        } else {
          AppLogger.w(
            "Preferences file not found at: ${prefsFile.path}",
            tag: 'PreferencesHelper',
          );
        }
      } else if (Platform.isAndroid) {
        AppLogger.w(
          "Cannot auto-delete prefs file on Android safely without access.",
          tag: 'PreferencesHelper',
        );
      }
    } catch (e) {
      AppLogger.e(
        "Failed to delete corrupted file",
        tag: 'PreferencesHelper',
        error: e,
        persistToHistory: false,
      );
    }
  }
}
