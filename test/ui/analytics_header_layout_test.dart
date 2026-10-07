import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/ui/analytics_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final width in [886.0, 420.0, 360.0, 320.0]) {
    testWidgets('Analytics group selector fits at width $width',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.windows),
        home: const Scaffold(),
        initialRoute: '/analytics',
        routes: {
          '/analytics': (_) => const AnalyticsScreen(groupKey: 'GPV2.1'),
        },
      ));
      await tester.pump();

      final appBarRect = tester.getRect(find.byType(AppBar));
      final groupButton = find.byTooltip('Вибрати чергу');
      final groupRect = tester.getRect(groupButton);
      expect(groupRect.top, greaterThanOrEqualTo(appBarRect.top));
      expect(
          groupRect.bottom, lessThanOrEqualTo(appBarRect.top + kToolbarHeight));
      expect(groupRect.left, greaterThanOrEqualTo(0));
      expect(groupRect.right, lessThanOrEqualTo(width));
      expect(groupRect.height, greaterThanOrEqualTo(36));
      final modeRect = tester.getRect(
          find.byType(CupertinoSlidingSegmentedControl<DataSourceMode>));
      final tabsRect = tester.getRect(find.byType(TabBar));
      expect(
          modeRect.top, greaterThanOrEqualTo(appBarRect.top + kToolbarHeight));
      expect(modeRect.bottom, lessThanOrEqualTo(tabsRect.top));
      expect(tester.takeException(), isNull);

      await tester.tap(groupButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(12));
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Група 3.1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.descendant(of: groupButton, matching: find.text('Група 3.1')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
