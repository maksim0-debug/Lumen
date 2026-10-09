import 'package:flutter/services.dart';

class AndroidSystemDiagnostics {
  static const channel = MethodChannel('ua.maksim0.lumen/android_diagnostics');

  static Future<Map<String, dynamic>> networkState() async =>
      await channel.invokeMapMethod<String, dynamic>('networkState') ?? {};

  static Future<Map<String, dynamic>> snapshot(
          {bool includeHistory = false}) async =>
      await channel.invokeMapMethod<String, dynamic>(
          'snapshot', {'includeHistory': includeHistory}) ??
      {};
}
