#ifndef FLUTTER_PLUGIN_FIREBASE_CORE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FIREBASE_CORE_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef __cplusplus
extern "C" {
#endif

void FirebaseCorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_PLUGIN_FIREBASE_CORE_PLUGIN_C_API_H_
