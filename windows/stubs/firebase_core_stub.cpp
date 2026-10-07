#include <firebase_core/firebase_core_plugin_c_api.h>
#include <flutter_plugin_registrar.h>

// No-op stub implementation for firebase_core on Windows.
// Firebase is used exclusively for FCM push notifications on mobile platforms (Android/iOS).
// This stub prevents downloading and linking the ~10 GB Google Firebase C++ SDK on Windows.
extern "C" {
void FirebaseCorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef /*registrar*/) {
  // Intentionally no-op on Windows.
}
}
