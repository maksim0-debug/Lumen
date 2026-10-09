import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/hour_segment.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/darkness_theme_service.dart';
import 'package:lumen/theme/darkness_stage_style.dart';
import 'package:lumen/ui/widgets/home/predicted_mode_grid_cell.dart';
import 'package:lumen/ui/widgets/home/real_mode_grid_cell.dart';

Future<void> pumpCell(WidgetTester tester, Widget cell) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 76, height: 52, child: cell)),
        ),
      ),
    );

void main() {
  final service = DarknessThemeService();
  final stages = <DarknessStage?>[null, ...DarknessStage.values];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await service.setMode('off');
    await service.setAnimationsEnabled(false);
  });

  for (final stage in stages) {
    testWidgets('$stage renders all 24 hours at 320px without overflow',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: GridView.count(
              crossAxisCount: 4,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              childAspectRatio: 1.5,
              children: List.generate(
                24,
                (hour) => PredictedModeGridCell(
                  hour: hour,
                  status: LightStatus.values[hour % LightStatus.values.length],
                  stage: stage,
                ),
              ),
            ),
          ),
        ),
      ));
      expect(find.byType(Text), findsNWidgets(24));
      expect(find.byType(Icon), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final status in LightStatus.values) {
      testWidgets('$stage $status shows time without decorative icons',
          (tester) async {
        await pumpCell(
          tester,
          PredictedModeGridCell(hour: 17, status: status, stage: stage),
        );

        final uncertain =
            status == LightStatus.maybe || status == LightStatus.unknown;
        expect(find.text(uncertain ? '17:00 ?' : '17:00'), findsOneWidget);
        expect(find.byType(Icon), findsNothing);
        expect(tester.takeException(), isNull);

        if (status == LightStatus.semiOn || status == LightStatus.semiOff) {
          final style = DarknessStageStyle.of(stage);
          final container = tester.widget<Container>(find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration! as BoxDecoration).gradient != null,
          ));
          final decoration = container.decoration! as BoxDecoration;
          final gradient = decoration.gradient! as LinearGradient;
          final on = stage == DarknessStage.stalker
              ? const Color(0xFF0A1F0A)
              : style.onColor;
          final off = stage == DarknessStage.stalker
              ? const Color(0xFF1A0000)
              : style.offColor;
          expect(gradient.colors,
              status == LightStatus.semiOn ? [off, on] : [on, off]);
          expect(gradient.stops,
              stage == DarknessStage.solarpunk ? [0.45, 0.55] : [0.5, 0.5]);

          if (stage == DarknessStage.stalker) {
            final text = tester.widget<Text>(find.text('17:00'));
            expect(text.style!.color, const Color(0xFF39FF14));
            expect(decoration.border!.top.color,
                const Color(0xFF39FF14).withValues(alpha: 0.4));
          }
        }
      });
    }

    testWidgets('$stage retains the current-hour marker', (tester) async {
      await pumpCell(
        tester,
        PredictedModeGridCell(
          hour: 17,
          status: LightStatus.semiOn,
          stage: stage,
          isCurrentHour: true,
        ),
      );
      expect(find.text('17:00'), findsOneWidget);
      expect(find.byType(Icon), findsOneWidget);
      expect(
          find.byIcon(DarknessStageStyle.of(stage).currentHourStyle().dotIcon),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final viewMode in [
      ScheduleViewMode.history,
      ScheduleViewMode.tomorrow
    ]) {
      testWidgets('$stage real $viewMode has no decorative icons',
          (tester) async {
        await service.setMode(stage?.name ?? 'off');
        var longPressCount = 0;
        await pumpCell(
          tester,
          RealModeGridCell(
            hour: 17,
            viewMode: viewMode,
            segments: const [
              HourSegment(0, 0.5, Colors.red, status: LightStatus.off),
              HourSegment(0.5, 1, Colors.green, status: LightStatus.on),
            ],
            onLongPress: () => longPressCount++,
          ),
        );
        expect(find.text('17:00'), findsOneWidget);
        expect(find.byType(Icon), findsNothing);
        await tester.longPress(find.text('17:00'));
        expect(longPressCount, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('theme animations survive switching and unmounting clean tiles',
      (tester) async {
    await service.setAnimationsEnabled(true);
    for (final stage in stages) {
      await pumpCell(
        tester,
        PredictedModeGridCell(
          hour: 17,
          status: LightStatus.semiOn,
          stage: stage,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('17:00'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 12));
    expect(tester.takeException(), isNull);
    await service.setAnimationsEnabled(false);
  });
}
