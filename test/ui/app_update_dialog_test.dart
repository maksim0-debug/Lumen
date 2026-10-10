import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/app_update_info.dart';
import 'package:lumen/services/darkness_theme_service.dart';
import 'package:lumen/theme/app_theme.dart';
import 'package:lumen/ui/dialogs/app_update_dialog.dart';
import 'package:lumen/ui/state/app_update_notifier.dart';

const info = AppUpdateInfo(
    currentVersion: '1.2.1+11',
    latestVersion: '1.3.0',
    releaseTitle: 'Lumen v1.3.0',
    releaseNotes: 'Виправлено помилки та покращено роботу.',
    releaseUrl: 'https://github.com/maksim0-debug/Lumen/releases/tag/v1.3.0',
    hasUpdate: true);

class _Notifier extends AppUpdateNotifier {
  bool ignoreSucceeds = true;
  bool openSucceeds = true;
  int opens = 0;
  Completer<bool>? pendingOpen;

  @override
  AppUpdateState build() =>
      const AppUpdateState(status: AppUpdateStatus.available, updateInfo: info);

  @override
  Future<bool> ignoreVersion(String version) async {
    if (ignoreSucceeds) {
      state = state.copyWith(isIgnored: true, isBadgeDismissed: true);
    }
    return ignoreSucceeds;
  }

  @override
  Future<bool> openReleaseUrl(
      [String? targetUrl, String? targetVersion]) async {
    expect(targetUrl, info.releaseUrl);
    expect(targetVersion, info.latestVersion);
    opens++;
    if (pendingOpen != null) return pendingOpen!.future;
    return openSucceeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpDialog(WidgetTester tester,
      {ThemeData? theme,
      Size size = const Size(800, 700),
      double scale = 1,
      _Notifier? notifier,
      AppUpdateInfo details = info}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      appUpdateProvider.overrideWith(() => notifier ?? _Notifier()),
    ]);
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => AppUpdateDialog.show(context, details),
                    child: const Text('Open')))),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('shows release details and actions without verification UI',
      (tester) async {
    await pumpDialog(tester);
    expect(find.text('Доступне оновлення'), findsOneWidget);
    expect(find.text('v1.2.1+11'), findsOneWidget);
    expect(find.text('v1.3.0'), findsOneWidget);
    expect(find.text(info.releaseNotes), findsOneWidget);
    expect(find.text('Відкрити реліз на GitHub'), findsOneWidget);
    expect(find.textContaining('SLSA'), findsNothing);
    expect(find.textContaining('SHA-256'), findsNothing);
    expect(find.textContaining('Підтверджена збірка'), findsNothing);
  });

  final themes = <String, ThemeData>{
    'light': AppTheme.lightTheme,
    'dark': AppTheme.darkTheme,
    for (final stage in DarknessStage.values)
      stage.name: DarknessThemeService().getThemeForStage(stage),
  };
  for (final theme in themes.entries) {
    for (final configuration in [
      (const Size(320, 640), 1.0),
      (const Size(375, 812), 2.0),
      (const Size(812, 375), 3.0),
    ]) {
      testWidgets(
          'dialog fits ${theme.key} ${configuration.$1} text scale ${configuration.$2}',
          (tester) async {
        await pumpDialog(tester,
            theme: theme.value,
            size: configuration.$1,
            scale: configuration.$2);
        expect(tester.takeException(), isNull);
        await tester
            .ensureVisible(find.text('Пропустити цю версію (не нагадувати)'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Пропустити цю версію (не нагадувати)'));
        await tester.pumpAndSettle();
        expect(find.byType(AppUpdateDialog), findsNothing);
      });
    }
  }

  testWidgets('later dismisses only the displayed version and closes route',
      (tester) async {
    final container = await pumpDialog(tester);
    await tester.tap(find.text('Пізніше'));
    await tester.pumpAndSettle();
    expect(container.read(appUpdateProvider).isBadgeDismissed, isTrue);
    expect(find.byType(AppUpdateDialog), findsNothing);
  });

  testWidgets('close leaves the badge available', (tester) async {
    final container = await pumpDialog(tester);
    await tester.tap(find.byTooltip('Закрити'));
    await tester.pumpAndSettle();
    expect(container.read(appUpdateProvider).shouldShowBadge, isTrue);
    expect(find.byType(AppUpdateDialog), findsNothing);
  });

  testWidgets('ignore failure keeps dialog open and reports the error',
      (tester) async {
    final notifier = _Notifier()..ignoreSucceeds = false;
    final container = await pumpDialog(tester, notifier: notifier);
    await tester.tap(find.text('Пропустити цю версію (не нагадувати)'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsOneWidget);
    expect(find.text('Не вдалося зберегти вибір. Спробуйте ще раз.'),
        findsOneWidget);
    expect(container.read(appUpdateProvider).isIgnored, isFalse);
  });

  testWidgets('browser failure keeps dialog open and reports the error',
      (tester) async {
    await pumpDialog(tester, notifier: _Notifier()..openSucceeds = false);
    await tester.tap(find.text('Відкрити реліз на GitHub'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsOneWidget);
    expect(
        find.text('Не вдалося відкрити посилання у браузері'), findsOneWidget);
  });

  testWidgets('pending browser action cannot run twice or pop the home route',
      (tester) async {
    final pending = Completer<bool>();
    final notifier = _Notifier()..pendingOpen = pending;
    await pumpDialog(tester, notifier: notifier);
    await tester.tap(find.text('Відкрити реліз на GitHub'));
    await tester.pump();
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(notifier.opens, 1);
    await tester.tap(find.byTooltip('Закрити'));
    await tester.pumpAndSettle();
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only one dialog is opened and the guard resets on dismissal',
      (tester) async {
    await pumpDialog(tester);
    final context = tester.element(find.text('Open'));
    unawaited(AppUpdateDialog.show(context, info));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Закрити'));
    await tester.pumpAndSettle();
    unawaited(AppUpdateDialog.show(context, info));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsOneWidget);
  });
}
