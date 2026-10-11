import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:lumen/services/notification_service.dart';

class _Paths extends PathProviderPlatform {
  final Directory root;
  bool failSupport = false;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async {
    if (failSupport) {
      throw const FileSystemException('Support directory unavailable');
    }
    return p.join(root.path, 'support');
  }

  @override
  Future<String?> getTemporaryPath() async => p.join(root.path, 'temporary');
}

class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  InitializationSettings? settings;
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #initialize) {
      settings = call.positionalArguments[0] as InitializationSettings;
      return Future<bool?>.value(true);
    }
    return super.noSuchMethod(call);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Paths paths;
  late PathProviderPlatform originalPaths;
  var assetBytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumen-notification-icon-');
    originalPaths = PathProviderPlatform.instance;
    paths = _Paths(root);
    PathProviderPlatform.instance = paths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'flutter/assets', (_) async => ByteData.sublistView(assetBytes));
  });
  tearDown(() async {
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await root.delete(recursive: true);
  });

  group('Windows icon preparation', () {
    test('file exists with complete bytes before SDK initialization', () async {
      final plugin = _Plugin();
      final service = NotificationService.forTesting(plugin);
      await service.init(requestPermissions: false);
      final expected =
          p.join(root.path, 'support', 'windows_notification_icon.png');
      expect(plugin.settings?.windows?.iconPath, expected);
      expect(await File(expected).readAsBytes(), assetBytes);
      expect(service.createWindowsDetails().images, isEmpty);
      expect(await Directory(p.join(root.path, 'support')).list().length, 1);
    });

    test('same-length stale icon is replaced with no staging file left behind',
        () async {
      final icon =
          File(p.join(root.path, 'support', 'windows_notification_icon.png'));
      await icon.parent.create(recursive: true);
      await icon.writeAsBytes(List.filled(assetBytes.length, 0));
      await NotificationService.forTesting(_Plugin())
          .init(requestPermissions: false);
      expect(await icon.readAsBytes(), assetBytes);
      expect(await icon.parent.list().length, 1);
    });

    test('unchanged bytes retain the existing file modification time',
        () async {
      final icon =
          File(p.join(root.path, 'support', 'windows_notification_icon.png'));
      await icon.parent.create(recursive: true);
      await icon.writeAsBytes(assetBytes);
      final modified = DateTime(2020, 1, 1);
      await icon.setLastModified(modified);
      await NotificationService.forTesting(_Plugin())
          .init(requestPermissions: false);
      expect(await icon.lastModified(), modified);
    });

    test('directory lookup failure falls back to temporary storage', () async {
      paths.failSupport = true;
      final plugin = _Plugin();
      await NotificationService.forTesting(plugin)
          .init(requestPermissions: false);
      final expected =
          p.join(root.path, 'temporary', 'windows_notification_icon.png');
      expect(plugin.settings?.windows?.iconPath, expected);
      expect(await File(expected).readAsBytes(), assetBytes);
    });

    test(
        'support write failure also falls back without breaking initialization',
        () async {
      await File(p.join(root.path, 'support')).writeAsString('Not a directory');
      final plugin = _Plugin();
      await NotificationService.forTesting(plugin)
          .init(requestPermissions: false);
      expect(plugin.settings?.windows?.iconPath,
          p.join(root.path, 'temporary', 'windows_notification_icon.png'));
    });

    test('missing asset degrades to notification details without an icon',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (_) async => null);
      final plugin = _Plugin();
      final service = NotificationService.forTesting(plugin);
      await service.init(requestPermissions: false);
      expect(plugin.settings, isNotNull);
      expect(plugin.settings?.windows?.iconPath, isNull);
      expect(service.createWindowsDetails().images, isEmpty);
    });
  }, skip: !Platform.isWindows);
}
