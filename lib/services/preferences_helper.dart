import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
// import 'package:path/path.dart' as p; // Not strictly needed if we construct path manually or just use string concat for simplicity in this specific case, but safer to use join.
import 'package:path/path.dart' show join;

class PreferencesHelper {
  /// Otrimaty ekzemplyar SharedPreferences bezpechno.
  /// Yakshcho fayl poshkodzhenyi (FormatException), vin bude vydalenyj,
  /// i povernetsya novyj chystyj ekzemplyar.
  static Future<SharedPreferences> getSafeInstance() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      print("[PreferencesHelper] ❌ Error loading SharedPreferences: $e");
      if (e.toString().contains("FormatException") ||
          e.toString().contains("Unexpected character")) {
        print(
            "[PreferencesHelper] ⚠️ Detected corruption. Attempting to repair...");
        await _deletePreferencesFile();

        // Try again after deletion
        try {
          return await SharedPreferences.getInstance();
        } catch (e2) {
          print(
              "[PreferencesHelper] ❌ Failed to recover SharedPreferences: $e2");
          // Rethrow or return a mock/empty if feasible?
          // For now, rethrow because app might depend on it.
          throw e2;
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
          print(
              "[PreferencesHelper] 🧹 Deleted corrupted preferences file at: ${prefsFile.path}");
        } else {
          print(
              "[PreferencesHelper] ⚠️ Preferences file not found at: ${prefsFile.path}");
          // It might be in a different location depending on the library version/OS
          // But for shared_preferences_windows it is usually in ApplicationSupport.
        }
      } else if (Platform.isAndroid) {
        // Android corruption is harder to fix programmatically without clear data,
        // usually requires `pm clear` or reinstall, but `shared_preferences` flutter plugin
        // might handle some things. Direct file access to xml prefs on Android requires root usually
        // or execution within app sandbox.
        // However, Flutter's SharedPreferences implementation on Android uses standard Android SharedPreferences which are XML.
        // If the XML is corrupt, the Android framework throws.
        // We can try to clear it via the plugin if it allows, but if getInstance fails, we can't call .clear().
        // So for Android, we just log.
        print(
            "[PreferencesHelper] ⚠️ Cannot auto-delete prefs file on Android safely without access.");
      }
    } catch (e) {
      print("[PreferencesHelper] ❌ Failed to delete corrupted file: $e");
    }
  }
}
