import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:typed_data' show Endian;
import 'dart:ui' as ui;

import 'package:arcaea_manager/chart/aff_chart.dart';
import 'package:arcaea_manager/chart/chart_appearance.dart';
import 'package:arcaea_manager/chart/chart_arc_editor.dart';
import 'package:arcaea_manager/chart/chart_beat_grid.dart';
import 'package:arcaea_manager/chart/chart_delay_calibration.dart';
import 'package:arcaea_manager/chart/chart_compatibility.dart';
import 'package:arcaea_manager/chart/chart_editor_page.dart';
import 'package:arcaea_manager/chart/chart_editor_visibility.dart';
import 'package:arcaea_manager/chart/chart_files.dart';
import 'package:arcaea_manager/chart/chart_feedback.dart';
import 'package:arcaea_manager/chart/chart_hit_regions.dart';
import 'package:arcaea_manager/chart/chart_hit_region_editor.dart';
import 'package:arcaea_manager/chart/chart_keyframes.dart';
import 'package:arcaea_manager/chart/chart_perspective.dart';
import 'package:arcaea_manager/chart/chart_playback_view.dart';
import 'package:arcaea_manager/chart/chart_playback_view_editor.dart';
import 'package:arcaea_manager/chart/chart_practice_segment.dart';
import 'package:arcaea_manager/chart/chart_preview_page.dart';
import 'package:arcaea_manager/chart/chart_skin.dart';
import 'package:arcaea_manager/chart/chart_timeline.dart';
import 'package:arcaea_manager/services/arc_storage.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PracticeJudgements _practiceJudgements(WidgetTester tester) {
  final field = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.foregroundPainter is PracticeFeedbackPainter,
    ),
  );
  return (field.foregroundPainter! as PracticeFeedbackPainter).judgements;
}

final _preparation = find.byKey(const ValueKey('practice-preparation'));

Future<void> _startPlayback(WidgetTester tester) async {
  await tester.tap(find.byTooltip('播放'));
  await tester.pump();
  if (_preparation.evaluate().isNotEmpty) {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
    }),
  );

  test('底端延长和天空高度改变相应的投影范围', () {
    final timeline = ChartTimeline(AffChart.parse(AffChart.blank));
    const defaults = defaultChartPlaybackView;
    const size = Size(850, 600);
    final normal = PerspectiveGeometry.forPlayback(
      size,
      0,
      2100,
      timeline,
      ChartLaneMode.four,
    );
    final updated = PerspectiveGeometry.forPlayback(
      size,
      0,
      2100,
      timeline,
      ChartLaneMode.four,
      view: (
        width: defaults.width,
        length: defaults.length,
        pitch: defaults.pitch,
        height: defaults.height,
        runout: 1.5,
        skyHeight: 1.25,
      ),
    );
    expect(updated.near, closeTo(normal.near * 1.5, 1e-8));
    expect(updated.project(.5, 0, updated.near).dy, closeTo(size.height, 1e-8));
    expect(updated.project(.5, 0, 0).dy, lessThan(normal.project(.5, 0, 0).dy));
    expect(
      updated.projectAir(.5, 1, 0).dy,
      lessThan(normal.projectAir(.5, 1, 0).dy),
    );
    expect(decodeChartPlaybackView('{"width":1.2}').skyHeight, 1);
  });

  test('校准补偿、第二个小拍退场与鼓点 PCM 周期', () {
    expect(calibrationError(2020, 0), -20);
    expect(calibrationError(2020, 20), 0);
    expect(calibrationError(2020, 35), 15);
    expect(calibrationLineEnd(2020, 0), 3000);
    expect(calibrationLineEnd(2020, 75), 2925);
    expect(calibrationVisualTime(2000, 75), 1925);
    final wave = calibrationDrums();
    final data = ByteData.sublistView(wave);
    expect(String.fromCharCodes(wave.take(4)), 'RIFF');
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint32(40, Endian.little), 24000 * 18 * 2);
    int peak(int beat) => List.generate(
      2000,
      (i) => data.getInt16(44 + (beat * 12000 + i) * 2, Endian.little).abs(),
    ).reduce((a, b) => a > b ? a : b);
    expect(wave.skip(44).take(24000 * 2 * 2), everyElement(0));
    expect(peak(4), greaterThan(peak(5)));
    expect(peak(5), peak(7));
    for (var bar = 2; bar <= 8; bar++) {
      final start = 44 + bar * 24000 * 2 * 2;
      expect(
        wave.skip(start).take(24000 * 2 * 2),
        orderedEquals(wave.skip(44 + 24000 * 2 * 2).take(24000 * 2 * 2)),
      );
    }
  });

  testWidgets('开始和重开时先走满三秒谱面，音频随后开始', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    const audio = MethodChannel('arcaea_manager/chart_audio');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var plays = 0;
    Completer<void>? startAudio;
    messenger.setMockMethodCallHandler(audio, (call) async {
      switch (call.method) {
        case 'open':
          return 5000;
        case 'seek':
          return (call.arguments as Map)['position'];
        case 'play':
          plays++;
          await (startAudio = Completer<void>()).future;
        case 'position':
          return [0, true];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(audio, null));
    final chart = AffChart.parse('${AffChart.blank}(0,2);(2000,3);');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          audio: () async => {'file': 'test.ogg'},
          debugElapsedMilliseconds: () => 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
    );
    double position() =>
        (tester.widget<CustomPaint>(field).painter! as ChartPerspectivePainter)
            .position
            .value;
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    for (var expected = 1; expected <= 2; expected++) {
      expect(_preparation, findsOneWidget);
      expect(position(), -3000);
      expect(plays, expected - 1);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(position(), -1);
      expect(plays, expected - 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('practice-pause-menu')), findsNothing);
      expect(position(), 0);
      startAudio!.complete();
      await tester.pump();
      expect(_preparation, findsNothing);
      expect(position(), 0);
      expect(plays, expected);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      if (expected == 1) {
        await tester.tap(find.text('重开'));
        await tester.pump();
      }
    }
  });

  testWidgets('段落练习的标记、三秒准备、裁切与到点结算', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}(500,2);hold(800,5000,2);(2000,3);'
      'arc(1000,3500,0.25,0.8,s,0.7,1,1,none,false);'
      '(3990,2);(4000,3);(4500,3);',
    );
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    final graph = find.byType(PracticeDensityTrack);
    final toggle = find.byKey(const ValueKey('practice-segment-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final before = tester.widget<PracticeDensityTrack>(graph);
    expect(
      before.density.fold<int>(0, (sum, bin) => sum + bin),
      greaterThan(3),
    );
    await tester.ensureVisible(graph);
    final rect = tester.getRect(graph);
    await tester.dragFrom(
      rect.topLeft + const Offset(16, 28),
      Offset((rect.width - 32) * 1500 / (before.max - before.min), 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<PracticeDensityTrack>(graph).segment!.start,
      greaterThan(1000),
    );
    await tester.dragFrom(
      rect.topRight + const Offset(-16, 28),
      Offset(-(rect.width - 32) * 1000 / (before.max - before.min), 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<PracticeDensityTrack>(graph).segment!.end,
      lessThan(before.max - 500),
    );
    const segment = (start: 1500.0, end: 4000.0);
    tester.widget<PracticeDensityTrack>(graph).onSegment(segment);
    await tester.pumpAndSettle();
    expect(
      segment.showsBody(
        timeline.notes.singleWhere((note) => note.kind == AffKind.hold),
      ),
      isFalse,
    );
    expect(
      segment.showsBody(
        timeline.notes.singleWhere((note) => note.kind == AffKind.arc),
      ),
      isTrue,
    );
    final play = find.text('返回游戏');
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pump();
    final field = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
    );
    ChartPerspectivePainter painter() =>
        tester.widget<CustomPaint>(field).painter! as ChartPerspectivePainter;
    expect(painter().position.value, -1500);
    expect(painter().practiceSegment, segment);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(painter().position.value, 1500);
    expect(find.byKey(const ValueKey('practice-pause-menu')), findsNothing);
    elapsed = 2501;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(painter().position.value, 4000);
    expect(find.text('试玩结果'), findsOneWidget);
    expect(
      _practiceJudgements(
        tester,
      ).history.every((result) => result.key != PracticeKey.hold),
      isTrue,
    );
    final ground = _practiceJudgements(
      tester,
    ).history.where((result) => result.key == PracticeKey.ground);
    expect(ground.length, 2);
    expect(
      ground.every((result) => result.grade == PracticeGrade.lost),
      isTrue,
    );
  });

  testWidgets('暂停可拖动判定四边形并保存分键型时间窗', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(3000,2);');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('判定范围'));
    await tester.pumpAndSettle();
    final editor = find.byType(ChartHitRegionEditor);
    expect(editor, findsOneWidget);
    await tester.tap(find.byTooltip('展开判定参数'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hit-area-shape')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义四边形').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起判定参数'));
    await tester.pump();
    final canvas = find.descendant(
      of: editor,
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
      ),
    );
    final box = tester.getRect(canvas);
    final g = PerspectiveGeometry.forPlayback(
      box.size,
      0,
      2100,
      ChartTimeline(AffChart.parse(AffChart.blank)),
      ChartLaneMode.four,
    );
    final frame = ChartHitFrame.ground(.125, space: g)!;
    const quad = ChartHitArea(shape: ChartHitShape.quadrilateral);
    final first = box.topLeft + frame.handles(quad).first;
    final drag = await tester.startGesture(first);
    await drag.moveBy(const Offset(-20, -12));
    await drag.up();
    await tester.pump();
    await tester.tap(find.byTooltip('展开判定参数'));
    await tester.pump();
    await tester.tap(find.text('时间判定'));
    await tester.pump();
    expect(find.textContaining('默认大 PURE 0–25 ms'), findsOneWidget);
    final fields = find.descendant(
      of: editor,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, '37');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('3D'));
    await tester.pump();
    expect(tester.widget<TextField>(fields.first).controller!.text, '25');
    await tester.enterText(fields.first, '32');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    final areas = decodeChartHitAreas(
      prefs.getString('chart_practice_hit_areas_3d'),
    );
    expect(areas[ChartHitKind.tap]!.shape, ChartHitShape.quadrilateral);
    expect(areas[ChartHitKind.tap]!.vertices.first.dx, lessThan(-1));
    expect(
      decodePracticeWindows(
        prefs.getString('chart_practice_timing_windows_3d'),
      )[PracticeKey.ground]!.early.shiny,
      37,
    );
    expect(
      decodeChartHitAreas(prefs.getString('chart_practice_hit_areas_2d')),
      isEmpty,
    );
    expect(
      decodePracticeWindows(
        prefs.getString('chart_practice_timing_windows_2d'),
      )[PracticeKey.ground]!.early.shiny,
      32,
    );
  });

  testWidgets('试玩使用自定义范围、时窗和输入补偿结算', (tester) async {
    const windows = (
      early: (shiny: 45.0, pure: 50.0, far: 60.0, capture: 120.0),
      late: null,
    );
    SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
      'chart_practice_input_delay_ms': 20,
      'chart_practice_hit_areas': encodeChartHitAreas({
        ChartHitKind.tap: const ChartHitArea(
          shape: ChartHitShape.square,
          width: .45,
        ),
      }),
      'chart_practice_timing_windows': encodePracticeWindows({
        PracticeKey.ground: windows,
      }),
    });
    final chart = AffChart.parse('${AffChart.blank}(100,2);(300,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final box = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
      ),
    );
    final frame = ChartHitFrame.ground(
      .375,
      flat: TimelineGeometry(box.size, 0, 2100),
    )!;
    elapsed = 157;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tapAt(
      box.topLeft + frame.center.translate(frame.radius * .8, 0),
    );
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 0);
    await tester.tapAt(box.topLeft + frame.center);
    await tester.pump();
    expect(
      _practiceJudgements(tester).history.single.grade,
      PracticeGrade.shiny,
    );
    expect(_practiceJudgements(tester).history.single.offset, -37);
    expect(_practiceJudgements(tester).history.single.windows, windows);
    elapsed = 390;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tapAt(box.topLeft + frame.center);
    await tester.pump();
    expect(_practiceJudgements(tester).lost, 1);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('延迟校准可直接分别设置提前和延后的判定时间窗', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(1000,2);');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('延迟校准'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('判定时间窗'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final editor = find.byType(ChartHitRegionEditor);
    final toggle = find.text('提前与延后独立设置');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    final fields = find.descendant(
      of: editor,
      matching: find.byType(TextField),
    );
    Future<void> enter(String value) async {
      await tester.ensureVisible(fields.first);
      await tester.enterText(fields.first, value);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    await enter('-15');
    await tester.ensureVisible(find.text('延后（+）'));
    await tester.tap(find.text('延后（+）'));
    await tester.pump();
    await enter('41');
    final keyPicker = find.byType(DropdownButton<PracticeKey>);
    await tester.ensureVisible(keyPicker);
    await tester.tap(keyPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('长按').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<TextField>(fields.first).controller!.text, '-125');
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(find.descendant(of: editor, matching: find.text('应用')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final calibration = find.byType(ChartDelayCalibration);
    expect(calibration, findsOneWidget);
    await tester.tap(
      find.descendant(of: calibration, matching: find.text('应用')),
    );
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    final timing = decodePracticeWindows(
      prefs.getString('chart_practice_timing_windows_3d'),
    )[PracticeKey.ground]!;
    expect(timing.early.shiny, 15);
    expect(timing.after.shiny, 41);
    expect(
      decodePracticeWindows(
        prefs.getString('chart_practice_timing_windows_3d'),
      ).containsKey(PracticeKey.hold),
      isFalse,
    );
    expect(
      decodePracticeWindows(
        prefs.getString('chart_practice_timing_windows_2d'),
      ),
      isEmpty,
    );
  });

  testWidgets('实际试玩分别应用两侧 PURE、FAR 和 LOST 点击上限', (tester) async {
    const windows = (
      early: (shiny: 12.0, pure: 29.0, far: 43.0, capture: 55.0),
      late: (shiny: 31.0, pure: 51.0, far: 71.0, capture: 91.0),
    );
    SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
      'chart_practice_timing_windows_3d': encodePracticeWindows({
        PracticeKey.ground: windows,
      }),
    });
    final chart = AffChart.parse('${AffChart.blank}(500,2);(900,2);(1400,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final report = _practiceJudgements(tester);
    Future<void> tapAt(double time) async {
      elapsed = time;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    }

    await tapAt(444);
    expect(report.history, isEmpty);
    await tapAt(445);
    await tapAt(945);
    await tapAt(1471);
    expect(report.history.map((item) => (item.offset, item.grade)), [
      (55.0, PracticeGrade.lost),
      (-45.0, PracticeGrade.pure),
      (-71.0, PracticeGrade.far),
    ]);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('旧版对称时间窗可读，独立时间窗保留两侧和持续键上限', () {
    final legacy = decodePracticeWindows(
      '{"ground":[20,50,100,120],"hold":[24,24,24,24]}',
    );
    expect(legacy[PracticeKey.ground]?.late, isNull);
    expect(legacy[PracticeKey.ground]?.after.shiny, 20);
    expect(legacy[PracticeKey.hold]?.after.capture, 24);
    final asymmetric = (
      early: sustainWindowSide(20),
      late: sustainWindowSide(70),
    );
    final saved = decodePracticeWindows(
      encodePracticeWindows({PracticeKey.hold: asymmetric}),
    );
    final hold = saved[PracticeKey.hold]!;
    expect(hold, asymmetric);
    expect(practiceGradeAt(hold, 25), PracticeGrade.lost);
    expect(practiceGradeAt(hold, -70), PracticeGrade.shiny);
    expect(practiceGradeAt(hold, -71), PracticeGrade.lost);
  });

  testWidgets('音频结束后保留补偿尾窗，晚到的输入仍可命中', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
      'chart_practice_input_delay_ms': 250,
    });
    const audio = MethodChannel('arcaea_manager/chart_audio');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      audio,
      (call) async => switch (call.method) {
        'open' => 5000,
        'seek' => (call.arguments as Map)['position'],
        'position' => [5000, false],
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(audio, null));
    final chart = AffChart.parse('${AffChart.blank}(4900,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          audio: () async => {'file': 'test.ogg'},
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final report = _practiceJudgements(tester);
    elapsed = 5000;
    await tester.pump(const Duration(milliseconds: 176));
    expect(find.text('试玩结果'), findsNothing);
    elapsed = 5150;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(report.history.single.offset, 0);
    expect(report.history.single.grade, PracticeGrade.shiny);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(find.text('试玩结果'), findsOneWidget);
  });

  testWidgets('输入补偿不改变滑键屏幕方向', (tester) async {
    SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
      'chart_practice_input_delay_ms': 500,
    });
    final chart = AffChart.parse('${AffChart.blank}flick(1000,0.5,0.2,0,1);');
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final box = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
      ),
    );
    elapsed = 1500;
    await tester.pump(const Duration(milliseconds: 16));
    final g = PerspectiveGeometry.forPlayback(
      box.size,
      1500,
      2100,
      timeline,
      ChartLaneMode.four,
    );
    final finger = await tester.startGesture(
      box.topLeft + g.projectAir(.5, .2, 1500),
    );
    await finger.moveBy(const Offset(0, -35));
    await finger.up();
    await tester.pump();
    expect(
      _practiceJudgements(tester).history.single.grade,
      PracticeGrade.shiny,
    );
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('全屏天空线高度随画面适配，空中音符共享纵向标尺', () {
    final timeline = ChartTimeline(AffChart.parse(AffChart.blank));
    for (final size in [
      const Size(1024, 768),
      const Size(1194, 834),
      const Size(850, 480),
      const Size(900, 390),
      const Size(390, 844),
    ]) {
      for (final mode in [ChartLaneMode.four, ChartLaneMode.six]) {
        final g = PerspectiveGeometry.forPlayback(
          size,
          0,
          2100,
          timeline,
          mode,
        );
        final sky = g.projectAir(.5, g.skyLineHeight, 0).dy;
        expect(sky / size.height, inInclusiveRange(.40, .55));
        expect(g.projectAir(.5, .35, 0).dy, greaterThan(sky));
        expect(g.projectAir(.5, 1.1, 0).dy, lessThan(sky));
        expect(g.project(.5, 0, g.near).dy, closeTo(size.height, 1e-8));
      }
    }
  });

  test('定制视角同步拉伸轨道、天空键与其坐标反算', () {
    const size = Size(1024, 768);
    final timeline = ChartTimeline(AffChart.parse(AffChart.blank));
    PerspectiveGeometry geometry(ChartPlaybackView view) =>
        PerspectiveGeometry.forPlayback(
          size,
          1000,
          2100,
          timeline,
          ChartLaneMode.six,
          view: view,
        );
    final normal = geometry(defaultChartPlaybackView);
    final wide = geometry((
      width: 1.5,
      length: 1,
      pitch: 0,
      height: 0,
      runout: 1.0,
      skyHeight: 1.0,
    ));
    expect(wide.width, closeTo(normal.width * 1.5, 1e-8));
    Offset key(PerspectiveGeometry g, double x) =>
        g.projectArcTap(x, .82, g.time);
    final original = key(normal, .7);
    final adjusted = key(wide, .7);
    expect(
      adjusted.dx - size.width / 2,
      closeTo((original.dx - size.width / 2) * 1.5, 1e-8),
    );
    expect(adjusted.dy, closeTo(original.dy, 1e-8));
    expect(
      (key(wide, .8) - key(wide, .6)).distance,
      closeTo((key(normal, .8) - key(normal, .6)).distance * 1.5, 1e-8),
    );
    expect(wide.pick(adjusted, air: true, arcTap: true)!.x, closeTo(.7, 1e-7));
    final shift = geometry((
      width: 1,
      length: 1,
      pitch: 0,
      height: 10,
      runout: 1.0,
      skyHeight: 1.0,
    ));
    expect(key(shift, .7).dy, closeTo(original.dy - size.height * .1, 1e-8));
    final long = geometry((
      width: 1,
      length: 1.5,
      pitch: 0,
      height: 0,
      runout: 1.0,
      skyHeight: 1.0,
    ));
    expect(
      long.project(.5, 0, 1800).dy,
      lessThan(normal.project(.5, 0, 1800).dy),
    );
    final steep = geometry((
      width: 1,
      length: 1,
      pitch: 8,
      height: 0,
      runout: 1.0,
      skyHeight: 1.0,
    ));
    final shallow = geometry((
      width: 1,
      length: 1,
      pitch: -14,
      height: 0,
      runout: 1.0,
      skyHeight: 1.0,
    ));
    for (final adjusted in [steep, shallow]) {
      expect(
        adjusted.project(.5, 0, 1000).dy,
        closeTo(normal.project(.5, 0, 1000).dy, 1e-8),
      );
    }
    expect(
      steep.project(.5, 0, 1800).dy,
      lessThan(normal.project(.5, 0, 1800).dy),
    );
  });

  test('零倍冻结滚动时仍采用当前镜头与扩轨状态', () {
    final chart = AffChart.parse(
      '${AffChart.blank}camera(1000,6000,0,0,0,0,0,l,250);'
      'scenecontrol(1000,enwidenlanes,0,1);(1400,0);',
    );
    final timeline = ChartTimeline(chart);
    const size = Size(1024, 768);
    final frozen = PerspectiveGeometry.forPlayback(
      size,
      0,
      2100,
      timeline,
      ChartLaneMode.automatic,
      sceneTime: 1400,
    );
    final live = PerspectiveGeometry.forPlayback(
      size,
      1400,
      2100,
      timeline,
      ChartLaneMode.automatic,
    );
    expect(frozen.playbackLanes, 1);
    expect(frozen.project(-.125, 0, 0), live.project(-.125, 0, 1400));
  });

  testWidgets('暂停菜单的视角编辑实时预览并保存超出推荐值的输入', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(1000,2);');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('3D 游玩视角'));
    await tester.pumpAndSettle();
    final editor = find.byType(ChartPlaybackViewEditor);
    expect(editor, findsOneWidget);
    final field = find.byKey(const ValueKey(ChartViewAxis.width));
    final sample = find.descendant(
      of: editor,
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
      ),
    );
    ChartPerspectivePainter painter() =>
        tester.widget<CustomPaint>(sample).painter! as ChartPerspectivePainter;
    final sliders = find.descendant(of: editor, matching: find.byType(Slider));
    tester.widget<Slider>(sliders.first).onChanged!(1.2);
    await tester.pump();
    expect(painter().playbackView.width, 1.2);
    await tester.enterText(field, '2.25');
    await tester.pump();
    expect(painter().playbackView.width, 2.25);
    expect(find.textContaining('超出推荐范围'), findsOneWidget);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    final settings = await SharedPreferences.getInstance();
    expect(
      decodeChartPlaybackView(settings.getString('chart_playback_view')).width,
      2.25,
    );
  });

  testWidgets('定制视角后，移动到新位置的地键和天键都能命中', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}(400,1);'
      'arc(800,800,0.81,0.81,s,0.88,0.88,0,none,true)[arctap(800)];',
    );
    final timeline = ChartTimeline(chart);
    const view = (
      width: 1.65,
      length: 1.3,
      pitch: -4.0,
      height: 9.0,
      runout: 1.0,
      skyHeight: 1.0,
    );
    SharedPreferences.setMockInitialValues({
      'chart_practice_transition': false,
      'chart_playback_view': encodeChartPlaybackView(view),
    });
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final box = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
      ),
    );
    PerspectiveGeometry geometry(double time) =>
        PerspectiveGeometry.forPlayback(
          box.size,
          time,
          2100,
          timeline,
          ChartLaneMode.automatic,
          view: view,
        );
    elapsed = 400;
    await tester.pump(const Duration(milliseconds: 16));
    final ground = geometry(400);
    await tester.tapAt(
      box.topLeft + ground.project(.22, 0, (ground.time + ground.near) / 2),
    );
    elapsed = 800;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tapAt(
      box.topLeft + geometry(800).projectArcTap(1.10, .88, 800),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 2);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('自由地键横坐标与标准轨道及长按判定点一同保存', () {
    final original = AffChart.parse(AffChart.blank);
    final saved = AffChart.parse(
      original.appendToGroup(
        0,
        '(100,2);hold(200,600,1);',
        groundPositions: [.25, -.20],
        sustainJudgements: [
          null,
          [250],
        ],
      ),
    );
    expect(saved.errors, isEmpty);
    final notes = saved.events.where((note) => note.isGround).toList();
    expect(notes.map((note) => note.laneX), [.25, -.20]);
    expect(notes.map((note) => note.standardLaneX), [.375, .125]);
    expect(notes.last.sustainJudgements, [250]);
    final changed = AffChart.parse(
      saved.replaceEvents({notes.first: '(150,2);'}),
    );
    expect(changed.warnings, isEmpty);
    expect(
      changed.events.where((note) => note.isGround).map((note) => note.laneX),
      [.25, -.20],
    );
    expect(
      changed.events.singleWhere((note) => note.isSustain).sustainJudgements,
      [250],
    );
    final standard = AffChart.parse(
      changed.source
          .split('\n')
          .where((line) => !line.startsWith('GroundPositions:'))
          .join('\n'),
    );
    expect(standard.errors, isEmpty);
    expect(
      standard.events.where((note) => note.isGround).map((note) => note.laneX),
      [.375, .125],
    );
  });

  testWidgets('迟到派发的触点按实际触碰时刻计分', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(200,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final canvas = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(canvas);
    final geometry = TimelineGeometry(box.size, 0, 2100);
    final position = box.topLeft + Offset(geometry.x(.375), geometry.judgement);
    elapsed = 363;
    await tester.pump(const Duration(milliseconds: 16));
    final at = Duration(microseconds: Timeline.now - 105000);
    await tester.sendEventToBinding(
      PointerDownEvent(pointer: 88, position: position, timeStamp: at),
    );
    await tester.sendEventToBinding(
      PointerUpEvent(pointer: 88, position: position, timeStamp: at),
    );
    await tester.pump();
    final result = _practiceJudgements(tester).history.single;
    expect(result.grade, PracticeGrade.far);
    expect(result.offset, closeTo(-58, 10));
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('判定时窗按大 P、小 P、FAR 和 LOST 分级，连击遇 LOST 清零', () {
    final report = PracticeJudgements();
    for (final (offset, grade) in <(double?, PracticeGrade)>[
      (-25, PracticeGrade.shiny),
      (25.001, PracticeGrade.pure),
      (-50, PracticeGrade.pure),
      (100, PracticeGrade.far),
    ]) {
      expect(report.record(PracticeKey.air, offset, 0, null), grade);
    }
    expect(report.combo, 4);
    expect(
      report.record(PracticeKey.air, -100.01, 0, null),
      PracticeGrade.lost,
    );
    expect(
      report.record(PracticeKey.ground, null, 0, null),
      PracticeGrade.lost,
    );
    expect(report.bestCombo, 4);
    expect(report.combo, 0);
    expect((report.early, report.late, report.lost), (2, 1, 2));
    report.clear();
    expect(report.history, isEmpty);
    expect(report.count(PracticeGrade.shiny), 0);
  });

  test('手动持续判定点的默认对称窗口只给大 P 或 LOST', () {
    final report = PracticeJudgements();
    for (final key in [PracticeKey.hold, PracticeKey.snake]) {
      for (final offset in [-25.0, 0.0, 25.0]) {
        expect(report.record(key, offset, 0, null), PracticeGrade.shiny);
      }
      for (final offset in [-25.001, 25.001, 75.0, null]) {
        expect(report.record(key, offset, 0, null), PracticeGrade.lost);
      }
    }
    expect(report.count(PracticeGrade.pure), 0);
    expect(report.count(PracticeGrade.far), 0);
  });

  test('自动持续判定点遵从起始 BPM 和密度，收尾不额外计数', () {
    final chart = ChartTimeline(
      AffChart.parse(
        'AudioOffset:0\nTimingPointDensityFactor:2\n-\n'
        'timing(0,120,4);hold(0,500,2);hold(0,60,3);'
        'arc(0,500,.2,.4,s,1,1,0,none,false);'
        'arc(500,1000,.4,.6,s,1,1,0,none,false);',
      ),
    );
    final notes = chart.notes;
    expect(
      chart.automaticSustainCheckpoints(
        notes.firstWhere((n) => n.end == 500 && n.kind == AffKind.hold),
      ),
      [125, 250, 375],
    );
    expect(
      chart.automaticSustainCheckpoints(notes.firstWhere((n) => n.end == 60)),
      [30],
    );
    expect(
      chart.automaticSustainCheckpoints(
        notes.firstWhere((n) => n.start == 500),
      ),
      [500, 625, 750, 875],
    );
    final stopped = ChartTimeline(
      AffChart.parse(
        'AudioOffset:0\n-\ntiming(0,0,4);timing(500,120,4);hold(100,1500,2);',
      ),
    );
    expect(stopped.automaticSustainCheckpoints(stopped.notes.single), [
      750,
      1000,
      1250,
    ]);
  });

  test('教程示例的低 BPM 和高 BPM 采用不同提前量，短相接蛇保留段首', () {
    final timeline = ChartTimeline(
      AffChart.parse(
        'AudioOffset:0\n-\ntiming(0,20,4);hold(46200,50400,2);'
        'timinggroup(){timing(0,178,4);timing(673,1424,4);'
        'timing(674,178,4);hold(673,2697,3);};'
        'timing(51000,120,4);arc(51000,52000,.2,.4,s,1,1,0,none,false);'
        'arc(52000,52040,.4,.6,s,1,1,0,none,false);',
      ),
    );
    final slow = timeline.sustainTicks(
      timeline.notes.firstWhere((note) => note.start == 46200),
    );
    expect(slow.single, (time: 48300, early: 750.0));
    final fast = timeline.sustainTicks(
      timeline.notes.firstWhere((note) => note.start == 673),
    );
    expect(fast.length, 47);
    expect(fast.first, (time: 715, early: 21.0));
    final join = timeline.sustainTicks(
      timeline.notes.firstWhere((note) => note.start == 52000),
    );
    expect(join.single, (time: 52000, early: 0.0));
    final sparse = ChartTimeline(
      AffChart.parse(
        'AudioOffset:0\nTimingPointDensityFactor:1e-310\n-\ntiming(0,120,4);'
        'arc(0,100,.5,.5,s,1,1,0,none,false);'
        'arc(100,200,.5,.5,s,1,1,0,none,false);',
      ),
    );
    expect(sparse.sustainTicks(sparse.notes.last).single, (
      time: 100,
      early: 0.0,
    ));
  });

  testWidgets('自动长按的提前、晚接边界独立计时', (tester) async {
    final chart = AffChart.parse(
      'AudioOffset:0\n-\ntiming(0,20,4);'
      'hold(1000,5200,1);hold(1000,5200,2);hold(1000,5200,3);',
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    elapsed = 2349;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(_practiceJudgements(tester).history, isEmpty);
    elapsed = 2350;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    elapsed = 3600;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    elapsed = 3601;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    elapsed = 4000;
    await tester.pump(const Duration(milliseconds: 16));
    final history = _practiceJudgements(tester).history;
    expect(history.map((hit) => hit.grade), [
      PracticeGrade.shiny,
      PracticeGrade.shiny,
      PracticeGrade.lost,
    ]);
    expect(history.map((hit) => hit.offset), [750.0, -500.0, null]);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('提前接住长按时补齐头部，松开后不增加头判', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}hold(1000,2000,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final judgement =
        (tester.widget<CustomPaint>(field).painter! as ChartPerspectivePainter)
            .judgement!;
    elapsed = 930;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 16));
    expect(judgement.earlyHolds.single.start, 1000);
    expect(_practiceJudgements(tester).history, isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 16));
    expect(judgement.earlyHolds, isEmpty);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  for (final override in [false, true]) {
    testWidgets('晚接按当前蛇身判定（自定义窗口 $override）', (tester) async {
      if (override) {
        SharedPreferences.setMockInitialValues({
          'chart_practice_transition': false,
          'chart_practice_timing_windows_2d': encodePracticeWindows({
            PracticeKey.snake: sustainPracticeWindows(500),
          }),
        });
      }
      final chart = AffChart.parse(
        'AudioOffset:0\n-\ntiming(0,20,4);arc(0,1300,-.5,1.5,s,1,1,0,none,false);',
      );
      final timeline = ChartTimeline(chart);
      var elapsed = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChartPreviewPage(
            chart: chart,
            timeline: timeline,
            initial: 0,
            practice: true,
            debugElapsedMilliseconds: () => elapsed,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2D'));
      await tester.pump();
      await _startPlayback(tester);
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartTimelinePainter,
      );
      final box = tester.getRect(field);
      elapsed = 1100;
      final g = TimelineGeometry(box.size, elapsed, 2100);
      final note = timeline.notes.single;
      await tester.tapAt(
        box.topLeft +
            Offset(g.x(note.point(elapsed).x, airborne: true), g.judgement),
      );
      final hit = _practiceJudgements(tester).history.single;
      expect(hit.grade, PracticeGrade.shiny);
      expect(hit.offset, -450);
      expect(
        hit.sustainWindow,
        override ? isNull : (early: 650.0, late: 500.0),
      );
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
    });
  }

  test('淡紫曲线和双押连线不受 AFF 的引导曲线颜色编号影响', () async {
    const size = Size(800, 500);
    final position = ValueNotifier(0.0);
    addTearDown(position.dispose);
    final twoGround = '${AffChart.blank}(620,1);(620,4);';
    final groundAndSky =
        '$twoGround'
        'arc(580,720,0.50,0.50,s,0.9,0.9,0,none,true)[arctap(620)];';
    final twoSky =
        '$groundAndSky'
        'arc(620,620,0.95,0.95,s,0.3,0.3,1,none,true)[arctap(620)];';
    final groundChart = ChartTimeline(AffChart.parse(twoGround));
    final mixedChart = ChartTimeline(AffChart.parse(groundAndSky));
    final allChart = ChartTimeline(AffChart.parse(twoSky));
    final arc = mixedChart.notes.singleWhere((note) => note.trace);
    final variant = allChart.notes.lastWhere(
      (note) => note.trace && note != arc,
    );
    expect(ChartTimelinePainter.arcColor(arc), chartTraceColor);
    expect(ChartTimelinePainter.arcColor(variant), chartTraceColor);
    Future<ByteData> render(CustomPainter painter) async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final bitmap = await picture.toImage(800, 500);
      try {
        return (await bitmap.toByteData())!;
      } finally {
        bitmap.dispose();
        picture.dispose();
      }
    }

    int pixel(ByteData image, Offset at) =>
        image.getUint32((at.dy.round() * 800 + at.dx.round()) * 4);
    final g = PerspectiveGeometry(size, 0, 2100);
    final left = g.project(.125, .038, 620);
    final right = g.project(.875, .038, 620);
    final sky = g.projectArcTap(.5, .9, 620);
    final otherSky = g.projectArcTap(.95, .3, 620);
    final floorMiddle = (left + right) / 2;
    final ground = await render(
      ChartPerspectivePainter(groundChart, position, 2100),
    );
    final base = await render(
      ChartPerspectivePainter(
        ChartTimeline(AffChart.parse(AffChart.blank)),
        position,
        2100,
      ),
    );
    expect(pixel(ground, floorMiddle), pixel(base, floorMiddle));
    final mixed = await render(
      ChartPerspectivePainter(mixedChart, position, 2100),
    );
    for (final point in [(left + sky) / 2, (right + sky) / 2]) {
      expect(pixel(mixed, point), isNot(pixel(ground, point)));
    }
    final all = await render(ChartPerspectivePainter(allChart, position, 2100));
    expect(
      pixel(all, (sky + otherSky) / 2),
      isNot(pixel(mixed, (sky + otherSky) / 2)),
    );
    final judgement = ChartJudgement()
      ..hide(arc, 0, tap: 620, immediately: true);
    final hidden = await render(
      ChartPerspectivePainter(mixedChart, position, 2100, judgement: judgement),
    );
    expect(pixel(hidden, (left + sky) / 2), pixel(ground, (left + sky) / 2));
    final flat = TimelineGeometry(size, 0, 2100);
    final flatMiddle = Offset(
      (flat.x(.875) + flat.x(.5, airborne: true)) / 2,
      flat.y(620),
    );
    final flatGround = await render(
      ChartTimelinePainter(groundChart, position, 2100),
    );
    final flatMixed = await render(
      ChartTimelinePainter(mixedChart, position, 2100),
    );
    expect(pixel(flatGround, flatMiddle), isNot(pixel(flatMixed, flatMiddle)));
  });

  test('兼容检查分别识别 Arc4 和 ArcExt 写法，修复保留可转换的音符', () {
    final chart = AffChart.parse(
      'AudioOffset:12\r\nUnknownHeader:1\r\n-\r\n'
      'timing(0,120,4);\r\n'
      'scenecontrol(100,enwidenlane,0,1);\r\n'
      'scenecontrol(200,arcahvdistort,15,1);\r\n'
      'arc(300,300,0.2,0.8,s,0.7,0.7,3,none,false);\r\n'
      'arc(450,650,0.2,0.8,s,0.7,0.7,0,none,false,2.0);\r\n'
      'timinggroup(angleY=90,noinput){\r\n'
      'timing(0,120,4);\r\n};\r\n'
      'flick(700,0.4,0.6,1,0); // 注释\r\n',
    );
    expect(chart.errors, isEmpty);
    final old = ChartCompatibility(chart, ChartGameVersion.arc4);
    final current = ChartCompatibility(chart, ChartGameVersion.arcExt);
    expect(old.issues.map((e) => e.description), anyElement(contains('宽天键')));
    expect(
      current.issues.map((e) => e.description),
      anyElement(contains('flick')),
    );
    expect(
      current.issues.map((e) => e.description),
      isNot(anyElement(contains('宽天键'))),
    );
    final repairedOld = AffChart.parse(old.applyRepairs());
    expect(repairedOld.errors, isEmpty);
    expect(repairedOld.events.any((event) => event.variableArcTap), isFalse);
    expect(
      repairedOld.events.any((event) => event.kind == AffKind.flick),
      isTrue,
    );
    expect(
      repairedOld.events.any(
        (event) =>
            event.command == 'scenecontrol' &&
            event.arguments[1] == 'enwidenlanes',
      ),
      isTrue,
    );
    expect(
      repairedOld.events
          .singleWhere((event) => event.arcTaps.contains(300))
          .number(2),
      .5,
    );
    expect(
      ChartCompatibility(repairedOld, ChartGameVersion.arc4).issues,
      isEmpty,
    );
    final repairedNew = AffChart.parse(current.applyRepairs());
    expect(repairedNew.events.any((event) => event.hasSmoothness), isTrue);
    expect(repairedNew.events.any((event) => event.variableArcTap), isTrue);
    expect(
      repairedNew.events
          .singleWhere((event) => event.arcTaps.contains(700))
          .number(2),
      .4,
    );
    expect(
      ChartCompatibility(repairedNew, ChartGameVersion.arcExt).issues,
      isEmpty,
    );
    expect(repairedNew.source, contains('\r\n'));
  });

  test('Arc4 小数地键读取原坐标，两套写法可按目标转换', () {
    final legacy = AffChart.parse(
      'AudioOffset:0\n/*\n-\n*/\n- // separator\n'
      'timing(0,120,400000000000000000.00);\n'
      '(100,0.844);hold(200,300,-0.250);\n',
    );
    expect(legacy.errors, isEmpty);
    expect(legacy.events[1].laneX, .844);
    expect(legacy.events[2].laneX, -.25);
    final old = ChartCompatibility(legacy, ChartGameVersion.arc4);
    expect(old.issues.single.description, contains('注释'));
    final rewritten = old.applyRepairs();
    expect(rewritten, contains('(100,0.844);'));
    expect(rewritten, contains('hold(200,300,-0.250);'));
    expect(
      ChartCompatibility(
        AffChart.parse(rewritten),
        ChartGameVersion.arc4,
      ).issues,
      isEmpty,
    );
    final current = ChartCompatibility(legacy, ChartGameVersion.arcExt);
    final parsed = AffChart.parse(current.applyRepairs());
    expect(parsed.errors, isEmpty);
    expect(parsed.events[1].arguments.last, '4');
    expect(parsed.events[2].arguments.last, '0');
    final withExtension = AffChart.parse(
      AffChart.parse(
        AffChart.blank,
      ).appendToGroup(0, '(100,4);', groundPositions: [.844]),
    );
    final legacySource = ChartCompatibility(
      withExtension,
      ChartGameVersion.arc4,
    ).applyRepairs();
    expect(legacySource, isNot(contains('GroundPositions')));
    expect(AffChart.parse(legacySource).events.last.laneX, .844);
  });

  test('宽天键转旧版时保留附带的天键和叠键', () {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(100,100,0.2,0.8,s,0.7,0.7,3,none,false)'
      '[arctap(100),arctap(100)];',
    );
    final converted = AffChart.parse(
      ChartCompatibility(chart, ChartGameVersion.arc4).applyRepairs(),
    );
    final keys = converted.events.where((e) => e.kind == AffKind.arc).toList();
    expect(converted.errors, isEmpty);
    expect(keys.length, 3);
    expect(keys.every((e) => e.arcTaps.single == 100), isTrue);
    expect(keys.first.number(2), .5);
    expect(keys.last.number(2), .2);
  });

  test('叠键数量在 2D 与 3D 渲染，已判定的重叠天键从数量中扣除', () async {
    const size = Size(800, 500);
    const time = 450;
    final note = 'arc($time,$time,0.5,0.5,s,0.7,0.7,0,none,true)';
    ChartTimeline timeline(int count) => ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}$note[${List.filled(count, 'arctap($time)').join(',')}];',
      ),
    );
    final one = timeline(1), two = timeline(2);
    final position = ValueNotifier(0.0);
    addTearDown(position.dispose);
    final judgement = ChartJudgement();
    Future<List<int>> render(ChartTimeline chart, bool perspective) async {
      final painter = perspective
          ? ChartPerspectivePainter(chart, position, 2100, judgement: judgement)
          : ChartTimelinePainter(chart, position, 2100, judgement: judgement);
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(800, 500);
      try {
        return (await image.toByteData())!.buffer.asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    for (final perspective in [false, true]) {
      judgement.clear();
      final base = await render(one, perspective);
      expect(listEquals(await render(two, perspective), base), isFalse);
      judgement.hitTap(two.notes.single, time, 0);
      expect(listEquals(await render(two, perspective), base), isTrue);
    }
  });

  testWidgets('同位置的天键各自判定，跨帧命中的特效合并绘制', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(500,500,0.50,0.50,s,0.9,0.9,0,none,true)'
      '[arctap(500),arctap(500),arctap(500)];',
    );
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final field = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(field);
    final g = TimelineGeometry(box.size, 500, 2100);
    final center = box.topLeft + Offset(g.x(.5, airborne: true), g.judgement);
    elapsed = 500;
    await tester.pump(const Duration(milliseconds: 16));
    final first = await tester.startGesture(center);
    final second = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 16));
    final painter =
        tester.widget<CustomPaint>(field).painter! as ChartTimelinePainter;
    expect(_practiceJudgements(tester).hits, 2);
    expect(painter.judgement!.hitEffects.single.count, 2);
    expect(
      painter.judgement!.remainingTaps(timeline.notes.single, 500, elapsed),
      1,
    );
    elapsed = 516;
    await tester.pump(const Duration(milliseconds: 16));
    final third = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 3);
    expect(painter.judgement!.hitEffects.single.count, 3);
    expect(
      painter.judgement!.remainingTaps(timeline.notes.single, 500, elapsed),
      0,
    );
    await first.up();
    await second.up();
    await third.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('已点击的 120 ms LOST 消失，超出窗口的地键仍保留', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(200,2);(600,2);');
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    elapsed = 320;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    final field = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartPerspectivePainter,
      ),
    );
    final painter = field.painter! as ChartPerspectivePainter;
    expect(
      _practiceJudgements(tester).history.single.grade,
      PracticeGrade.lost,
    );
    expect(painter.judgement!.hidden(timeline.notes.first, elapsed), isTrue);
    expect(painter.judgement!.hitEffects, isEmpty);
    elapsed = 721;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(_practiceJudgements(tester).history, hasLength(1));
    expect(painter.judgement!.hidden(timeline.notes.last, elapsed), isFalse);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('自动长按可以中途补接，判定只给大 PURE', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}hold(0,1000,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    elapsed = 274;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    final report = _practiceJudgements(tester);
    expect(report.history.single.grade, PracticeGrade.shiny);
    expect(report.history.single.offset, -24);
    expect(report.late, 0);
    elapsed = 510;
    await tester.pump(const Duration(milliseconds: 16));
    expect(report.hits, 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('提前松开自动蛇会漏掉重接冷却中的判定点', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(0,1600,0.5,0.5,s,1,1,0,none,false);',
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final box = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
      ),
    );
    final g = TimelineGeometry(box.size, 0, 2100);
    final input = box.topLeft + Offset(g.x(.5, airborne: true), g.judgement);
    final first = await tester.startGesture(input);
    elapsed = 250;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 1);
    elapsed = 300;
    await first.up();
    elapsed = 450;
    final second = await tester.startGesture(input);
    elapsed = 500;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 1);
    elapsed = 1000;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 2);
    expect(_practiceJudgements(tester).lost, 0);
    elapsed = 1450;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).lost, 2);
    await second.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  for (final joined in [true, false]) {
    testWidgets(joined ? '相接蛇段交界后换手不触发重接冷却' : '同一蛇段有两指交接时不中断判定', (
      tester,
    ) async {
      final chart = AffChart.parse(
        'AudioOffset:0\n-\ntiming(0,600,4);\n'
        'arc(0,${joined ? 500 : 1000},0.5,0.5,s,1,1,0,none,false);'
        '${joined ? 'arc(500,1000,0.5,0.5,s,1,1,0,none,false);' : ''}',
      );
      final timeline = ChartTimeline(chart);
      var elapsed = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChartPreviewPage(
            chart: chart,
            timeline: timeline,
            practice: true,
            initial: 0,
            debugElapsedMilliseconds: () => elapsed,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2D'));
      await tester.pump();
      await _startPlayback(tester);
      final box = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
        ),
      );
      final g = TimelineGeometry(box.size, 0, 2100);
      final center = box.topLeft + Offset(g.x(.5, airborne: true), g.judgement);
      final first = await tester.startGesture(center);
      elapsed = 510;
      await tester.pump(const Duration(milliseconds: 16));
      expect(_practiceJudgements(tester).hits, 5);
      if (joined) await first.up();
      elapsed = 535;
      final second = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 16));
      if (!joined) await first.up();
      elapsed = 840;
      await tester.pump(const Duration(milliseconds: 16));
      expect(_practiceJudgements(tester).hits, 8);
      expect(_practiceJudgements(tester).lost, 0);
      await second.up();
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('流速滑块覆盖 −1 至 10，手输负倍率及零倍适用于两种视图', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(500,2);(3000,2);');
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: false,
          initial: 500,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final options = find.byTooltip('预览流速与延迟');
    await tester.tap(options);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final speedSlider = tester.widget<Slider>(
      find.descendant(of: dialog, matching: find.byType(Slider)).first,
    );
    expect(speedSlider.min, -1);
    expect(speedSlider.max, 10);
    await tester.enterText(find.byType(TextField), '-12.75');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final perspective =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (w) =>
                        w is CustomPaint &&
                        w.painter is ChartPerspectivePainter,
                  ),
                )
                .painter!
            as ChartPerspectivePainter;
    expect(perspective.reverse, isTrue);
    expect(perspective.lookahead, closeTo(2100 / 12.75, 1e-8));
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'chart_preview_scroll_speed',
      ),
      -12.75,
    );
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    ChartTimelinePainter flat() =>
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (w) =>
                        w is CustomPaint && w.painter is ChartTimelinePainter,
                  ),
                )
                .painter!
            as ChartTimelinePainter;
    expect(flat().reverse, isTrue);
    await tester.tap(options);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '-12.75',
    );
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(flat().frozenAt, 500);
    await _startPlayback(tester);
    elapsed = 200;
    await tester.pump(const Duration(milliseconds: 16));
    expect(flat().position.value, 700);
    expect(flat().frozenAt, 500);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('不同时间组的短蛇在两帧之间交叉时可以互换触点', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'arc(1000,1040,0,1,s,1,1,0,none,false);'
      'timinggroup(angley300){timing(0,120,4);'
      'arc(1000,1040,0.4,-0.2,s,1,1,1,none,false);};',
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final box = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
      ),
    );
    final geometry = TimelineGeometry(box.size, 0, 2100);
    Offset point(double x) =>
        box.topLeft + Offset(geometry.x(x, airborne: true), geometry.judgement);
    elapsed = 1000;
    final left = await tester.startGesture(point(0));
    final right = await tester.startGesture(point(.4));
    elapsed = 1005;
    await tester.pump(const Duration(milliseconds: 16));
    elapsed = 1018;
    await left.moveTo(point(.1));
    await right.moveTo(point(.5));
    elapsed = 1021;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 2);
    expect(_practiceJudgements(tester).lost, 0);
    await left.up();
    await right.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('反向滚动时两种渲染都保留判定线远侧的已过音符', () async {
    const size = Size(800, 500);
    const cursor = 1000.0;
    const lookahead = 2100.0;
    final position = ValueNotifier(cursor);
    addTearDown(position.dispose);
    final chart = ChartTimeline(
      AffChart.parse('${AffChart.blank}hold(600,800,2);'),
    );
    final empty = ChartTimeline(AffChart.parse(AffChart.blank));
    Future<int> pixel(CustomPainter painter, Offset at) async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(800, 500);
      try {
        return (await image.toByteData())!.getUint32(
          (at.dy.round() * 800 + at.dx.round()) * 4,
        );
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    final flat = TimelineGeometry(size, cursor, lookahead, reverse: true);
    final flatPoint = Offset(flat.x(.375), flat.y(700));
    expect(flatPoint.dy, lessThan(flat.judgement));
    expect(flat.time(flatPoint.dy), closeTo(700, 1e-8));
    final projected = PerspectiveGeometry(size, cursor, lookahead);
    final point = projected.project(.375, .038, 1300);
    expect(
      await pixel(
        ChartPerspectivePainter(chart, position, lookahead, reverse: true),
        point,
      ),
      isNot(
        await pixel(
          ChartPerspectivePainter(empty, position, lookahead, reverse: true),
          point,
        ),
      ),
    );
    expect(
      await pixel(
        ChartTimelinePainter(chart, position, lookahead, reverse: true),
        flatPoint,
      ),
      isNot(
        await pixel(
          ChartTimelinePainter(empty, position, lookahead, reverse: true),
          flatPoint,
        ),
      ),
    );
  });

  testWidgets('全屏试玩暂停后回放三秒，音符减半显示且不重复判定', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}(2000,1);(5000,1);(5500,1);hold(4900,5700,3);',
    );
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        raw.events.singleWhere((event) => event.isSustain): [5050],
      }),
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 4000,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    ChartPerspectivePainter painter() =>
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(tester.getTopLeft(canvas), Offset.zero);
    expect(tester.getSize(canvas), tester.getSize(find.byType(Scaffold)));
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('音乐音量'), findsNothing);
    final stats = find.byKey(const ValueKey('practice-summary'));
    expect(
      tester.getTopRight(stats).dx,
      greaterThan(tester.getSize(canvas).width * .9),
    );

    elapsed = 1000;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 1);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('音乐音量'), findsOneWidget);
    expect(find.byTooltip('游玩判定显示'), findsOneWidget);
    expect(find.byType(PracticeDensityTrack), findsOneWidget);
    elapsed = 0;
    await tester.tap(find.text('继续'));
    await tester.pump();
    expect(find.byKey(const ValueKey('practice-transition')), findsNothing);
    expect(painter().position.value, 2000);
    expect(painter().noteOpacity, .5);
    expect(painter().judgement, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(find.textContaining('大 P 1', findRichText: true), findsOneWidget);
    elapsed = 2990;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    elapsed = 3000;
    await tester.pump(const Duration(milliseconds: 16));
    expect(painter().noteOpacity, 1);
    expect(_practiceJudgements(tester).hits, 1);
    final alreadyHit = painter().timeline.notes.singleWhere(
      (note) => note.start == 5000,
    );
    expect(painter().judgement!.hidden(alreadyHit, 5000), isTrue);
    elapsed = 3050;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    elapsed = 3500;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 3);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('重开回到谱面开头，暂停可关闭过渡并返回编辑页', (tester) async {
    SharedPreferences.setMockInitialValues({'chart_practice_transition': true});
    final chart = AffChart.parse('${AffChart.blank}(8000,1);');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChartPreviewPage(
                    chart: chart,
                    timeline: ChartTimeline(chart),
                    practice: true,
                    initial: 4000,
                    debugElapsedMilliseconds: () => 0,
                  ),
                ),
              ),
              child: const Text('编辑页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑页'));
    await tester.pumpAndSettle();
    final transition = find.byKey(const ValueKey('practice-transition'));
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(transition, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 740));
    await tester.pump();
    expect(transition, findsNothing);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重开'));
    await tester.pump();
    expect(transition, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 425));
    await tester.pump();
    expect(transition, findsNothing);
    final field = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartPerspectivePainter,
      ),
    );
    expect((field.painter! as ChartPerspectivePainter).position.value, -3000);
    expect(_preparation, findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开场过渡动画'));
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('chart_practice_transition'), isFalse);
    await tester.tap(find.text('重开'));
    await tester.pump();
    expect(transition, findsNothing);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('编辑页'), findsOneWidget);
  });

  testWidgets('曲终显示结果，滑动进度重置实时统计', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(0,2);');
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    elapsed = 280;
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.textContaining('LOST 1'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    final graph = tester.widget<PracticeDensityTrack>(
      find.byType(PracticeDensityTrack),
    );
    graph.onSeek!(graph.max - 30);
    await tester.pumpAndSettle();
    expect(find.textContaining('LOST 0'), findsOneWidget);
    elapsed = 0;
    await tester.tap(find.text('继续'));
    await tester.pump();
    elapsed = 1010;
    await tester.pumpAndSettle();
    expect(find.text('试玩结果'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });

  testWidgets('判定预览显示关闭项，按选择展开设置并保存拖动位置', (tester) async {
    final chart = AffChart.parse(AffChart.blank);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('游玩判定显示'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('feedback-detail-panel'));
    final bar = find.byKey(const ValueKey('feedback-element-bar'));
    final timing = find.byKey(const ValueKey('feedback-element-timing'));
    final combo = find.byKey(const ValueKey('feedback-element-combo'));
    expect(panel, findsNothing);
    expect(bar, findsOneWidget);
    expect(timing, findsOneWidget);
    final originalCombo = tester.getCenter(combo);
    await tester.drag(combo, const Offset(52, 48));
    await tester.pumpAndSettle();
    expect(tester.getCenter(combo).dx, greaterThan(originalCombo.dx + 25));
    await tester.tapAt(const Offset(750, 90));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('详细设置'));
    await tester.pumpAndSettle();
    for (final item in FeedbackItem.values) {
      expect(
        find.descendant(of: panel, matching: find.text(item.label)),
        findsOneWidget,
      );
    }
    await tester.tap(find.byTooltip('详细设置'));
    await tester.pumpAndSettle();

    await tester.tap(
      bar,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.text('判定条')),
      findsOneWidget,
    );
    expect(find.descendant(of: panel, matching: find.text('连击')), findsNothing);
    final show = find.byKey(const ValueKey('feedback-show-bar'));
    expect(tester.widget<SwitchListTile>(show).value, isFalse);
    await tester.tap(show);
    await tester.pumpAndSettle();
    final width = find.byKey(const ValueKey('feedback-width-bar'));
    tester.widget<Slider>(width).onChanged!(.8);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('详细设置'));
    await tester.pumpAndSettle();
    final before = tester.getCenter(bar);
    await tester.drag(bar, const Offset(45, -90));
    await tester.pumpAndSettle();
    expect(tester.getCenter(bar).dy, lessThan(before.dy - 50));

    await tester.longPress(timing);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: panel,
        matching: find.text(FeedbackItem.timing.label),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('详细设置'));
    await tester.pumpAndSettle();
    await tester.tap(combo);
    await tester.pump(const Duration(milliseconds: 65));
    await tester.tap(combo);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.text(FeedbackItem.combo.label)),
      findsOneWidget,
    );

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    final settings = FeedbackSettings.decode(
      prefs.getString('chart_practice_feedback'),
    );
    expect(settings[FeedbackItem.bar].show, isTrue);
    expect(settings[FeedbackItem.bar].width, .8);
    expect(settings[FeedbackItem.bar].y, lessThan(.86));
    expect(settings[FeedbackItem.timing].show, isFalse);
  });

  testWidgets('结果图分别统计各键型的点击并忽略无点击时机的漏判', (tester) async {
    final report = PracticeJudgements()
      ..record(PracticeKey.ground, 23, 100, null)
      ..record(PracticeKey.ground, -40, 200, null)
      ..record(PracticeKey.air, -112, 300, null)
      ..record(PracticeKey.air, null, 400, null);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPracticeResults(context, report),
              child: const Text('查看结果'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();
    expect(find.text('偏差（ms） · 正值为提前'), findsOneWidget);
    expect(find.text('地键 2'), findsOneWidget);
    expect(find.text('天键 1'), findsOneWidget);
    expect(find.textContaining('LOST 2'), findsOneWidget);
    final air = find.widgetWithText(FilterChip, '天键 1');
    await tester.tap(air);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(air).selected, isFalse);
  });

  testWidgets('在编辑器添加扩轨事件，自动模式按时间启用及结束 6K', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('谱面菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('镜头与场景控制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加 4K／6K 切换'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '时间（毫秒）'),
      '1000',
    );
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final paint =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartPerspectivePainter,
                  ),
                )
                .painter!
            as ChartPerspectivePainter;
    expect(paint.timeline.scene.hasLaneEvents, isTrue);
    expect(paint.laneMode.expansion(paint.timeline, 999, editing: true), 0);
    expect(paint.laneMode.expansion(paint.timeline, 1000, editing: true), 1);
    expect(paint.laneMode.expansion(paint.timeline, 1000), 1);
    final reverted = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}scenecontrol(1000,enwidenlanes,100,1);scenecontrol(2000,enwidenlanes,0,0);',
      ),
    );
    expect(paint.laneMode.expansion(reverted, 1050), 0.5);
    expect(paint.laneMode.expansion(reverted, 2000), 0);
  });

  testWidgets('直接编辑 4K／6K 轨道和镜头事件，并可分别修改已有切换时间', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4K／6K 事件'));
    await tester.pumpAndSettle();
    Future<void> add(
      int time, {
      bool four = false,
      bool trackOnly = false,
    }) async {
      await tester.tap(find.text('添加 4K／6K 切换'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '时间（毫秒）'),
        '$time',
      );
      if (four) {
        final target = find.widgetWithText(
          DropdownButtonFormField<int>,
          '目标模式',
        );
        await tester.tap(target);
        await tester.pumpAndSettle();
        await tester.tap(find.text('4K').hitTestable().last);
        await tester.pumpAndSettle();
      }
      if (trackOnly) {
        await tester.enterText(
          find.widgetWithText(TextFormField, '过渡时长（毫秒）'),
          '200',
        );
        await tester.tap(
          find.widgetWithText(DropdownButtonFormField<String>, '切换对象'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('轨道').hitTestable().last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
    }

    await add(1000);
    await add(2100, four: true);
    await tester.tap(find.text('2100 ms · 镜头 → 4K'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '时间（毫秒）'),
      '1900',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '过渡时长（毫秒）'),
      '100',
    );
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('1900 ms · 镜头 → 4K'), findsOneWidget);
    expect(find.text('2100 ms · 轨道 → 4K'), findsOneWidget);
    await add(3000, trackOnly: true);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final view = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final painter =
        tester.widget<CustomPaint>(view).painter! as ChartPerspectivePainter;
    final data = painter.timeline;
    expect(painter.laneMode.expansion(data, 1000, editing: true), 1);
    expect(painter.laneMode.expansion(data, 2099, editing: true), 1);
    expect(painter.laneMode.expansion(data, 2100, editing: true), 0);
    expect(painter.laneMode.expansion(data, 3050, editing: true), 0.25);
    expect(data.scene.widenCamera(3200), 0);
    for (final editing in [true, false]) {
      for (final (time, widen) in [
        (999.0, 0),
        (1000.0, 1),
        (1950.0, 0.5),
        (2000.0, 0),
      ]) {
        final geometry = PerspectiveGeometry.forScene(
          tester.getSize(view),
          time,
          painter.lookahead,
          data.scene,
          editing: editing,
        );
        expect(geometry.widen, widen);
      }
    }
  });

  testWidgets('2D 拖动创建长按和同时间轴上的蛇／弧线', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await tester.tap(find.text('长按'));
    await tester.pump();
    Offset point(double x, int time, {bool air = false}) {
      final bounds = tester.getRect(canvas);
      final g = TimelineGeometry(bounds.size, 0, 2100);
      return bounds.topLeft +
          Offset(g.x(x, airborne: air), g.y(time.toDouble()));
    }

    final hold = await tester.startGesture(point(0.375, 250));
    await hold.moveTo(point(0.625, 1000));
    await hold.up();
    await tester.pumpAndSettle();
    final holdChart =
        (tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter)
            .timeline;
    final note = holdChart.notes.single;
    expect((note.start, note.end, note.laneX), (250, 1000, 0.375));
    for (final tool in ['蛇', '弧线']) {
      await tester.tap(find.text(tool));
      await tester.pump();
      final stroke = await tester.startGesture(point(0.1, 250, air: true));
      await stroke.moveTo(point(0.8, 625, air: true));
      await stroke.moveTo(point(0.2, 1000, air: true));
      await stroke.up();
      await tester.pumpAndSettle();
    }
    final timeline =
        (tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter)
            .timeline;
    final arcs = timeline.notes
        .where((note) => note.kind == AffKind.arc)
        .toList();
    expect(arcs, hasLength(4));
    expect(arcs.where((arc) => arc.trace), hasLength(2));
    expect(
      arcs.every((note) => note.number(5) == 1 && note.number(6) == 1),
      isTrue,
    );
    expect(
      arcs.any((note) => note.end == 625 && note.number(3) == 0.8),
      isTrue,
    );
  });

  testWidgets('可拖动判定面以外的天键，开启高度锁时 X 保持不变', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}arc(500,500,0.25,0.25,s,1,1,0,none,true)[arctap(500)];',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('3D 关键点显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('只显示天键关键点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('只调高度'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final bounds = tester.getRect(canvas);
    final before =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    final g = PerspectiveGeometry(
      bounds.size,
      before.position.value,
      before.lookahead,
    );
    final handle = before.keyframes!(g).single;
    expect(handle.tap, isTrue);
    await tester.dragFrom(bounds.topLeft + handle.point, const Offset(40, 32));
    await tester.pumpAndSettle();
    final after =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    final note = after.timeline.notes.single;
    expect(note.start, 500);
    expect(note.point(500).x, 0.25);
    expect(note.point(500).height, lessThan(1));
    await tester.tap(find.text('显示关键点'));
    await tester.pumpAndSettle();
    final disabled =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(disabled.keyframes, isNull);
    final hidden = after.keyframes!(g).toList();
    expect(hidden, isEmpty);
    final position = note.point(500);
    await tester.dragFrom(
      tester.getTopLeft(canvas) +
          g.projectArcTap(position.x, position.height, 500),
      const Offset(0, -26),
    );
    await tester.pumpAndSettle();
    final stationary =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(stationary.timeline.notes.single.point(500), position);
    await tester.tap(find.text('显示关键点'));
    await tester.pumpAndSettle();
    final restored =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(restored.keyframes!(g).single.tap, isTrue);
    await tester.tap(find.text('显示项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅显示选中'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter)
          .visibility
          ?.onlySelected,
      isTrue,
    );
    await tester.tap(find.text('3D 编辑'));
    await tester.pumpAndSettle();
    final flat =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartTimelinePainter,
                  ),
                )
                .painter!
            as ChartTimelinePainter;
    expect(flat.visibility?.onlySelected, isTrue);
    expect(flat.visibility?.selection.single.start, 500);
  });

  testWidgets('关闭 3D 关键点后判定面上的普通及宽天键仍绘制黄边', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}'
      'arc(500,500,0,0,s,0.6,0.6,0,none,true)[arctap(500)];'
      'arc(500,500,0.7,1.15,s,0.6,0.6,3,none,false);',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示关键点'));
    await tester.pumpAndSettle();
    final view = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final painter =
        tester.widget<CustomPaint>(view).painter! as ChartPerspectivePainter;
    expect(painter.keyframes, isNull);
    const size = Size(800, 520);
    final g = PerspectiveGeometry(size, 500, painter.lookahead);
    final samples = [
      for (final (left, right) in [
        (
          -PerspectiveGeometry.arcTapHalfWidth,
          PerspectiveGeometry.arcTapHalfWidth,
        ),
        (0.7, 1.15),
      ])
        Rect.fromPoints(
          g.projectArcTap(left, 0.6, 500),
          g.projectArcTap(right, 0.6, 500),
        ).inflate((g.width * 0.018).clamp(5.0, 12.0)).topCenter,
    ];
    await tester.runAsync(() async {
      for (final (cursor, expectYellow) in [(500.0, true), (450.0, false)]) {
        painter.position.value = cursor;
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(800, 520);
        try {
          final rgba = (await image.toByteData())!;
          for (final point in samples) {
            final found = [-1, 0, 1].any((dy) {
              final i = ((point.dy.round() + dy) * 800 + point.dx.round()) * 4;
              final r = rgba.getUint8(i),
                  g = rgba.getUint8(i + 1),
                  b = rgba.getUint8(i + 2);
              return r > 235 && g > 204 && b > 120 && b < 185;
            });
            expect(found, expectYellow, reason: '$cursor ms, sample $point');
          }
        } finally {
          image.dispose();
          picture.dispose();
        }
      }
    });
  });

  test('附着天键可在原时间拆分曲线成新的关键点，并保留其他判定点', () {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(200,800,0.0,1.0,siso,1,1,2,none,true)[arctap(300),arctap(500),arctap(700)];',
    );
    final original = chart.events.singleWhere(
      (note) => note.kind == AffKind.arc,
    );
    final key = chartKeyframes(original).singleWhere((key) => key.time == 500);
    final result = AffChart.parse(
      moveChartKeyframe(chart, key, key.position.x, 0.4),
    );
    expect(result.errors, isEmpty);
    final halves = result.events
        .where((note) => note.kind == AffKind.arc)
        .toList();
    expect(halves.map((arc) => arc.arguments[4]), ['siso', 'siso']);
    expect(halves.expand((arc) => arc.arcTaps), [300, 500, 700]);
    expect(halves.last.point(500), (x: key.position.x, height: 0.4));
  });

  testWidgets('显示菜单隔离单个附着天键，点击空白及修改其它事件后保留选择', (tester) async {
    const source =
        '${AffChart.blank}(650,1);\n'
        'arc(100,1500,0.3,0.3,s,0.8,0.8,0,none,true)[arctap(400),arctap(1200)];';
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    Future<void> editSource(String text) async {
      await tester.tap(find.text('AFF 源码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('aff-source')), text);
      await tester.tap(find.text('时间轴'));
      await tester.pumpAndSettle();
    }

    await editSource(source);
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    ChartTimelinePainter painter() =>
        tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter;
    Offset point(double x, double time) {
      final box = tester.getRect(canvas);
      final geometry = TimelineGeometry(box.size, 0, 2100);
      return box.topLeft +
          Offset(geometry.x(x, airborne: true), geometry.y(time));
    }

    await tester.tapAt(point(0.3, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅显示选中'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tapAt(point(1.1, 800));
    await tester.pumpAndSettle();
    await editSource(source.replaceFirst('(650,1)', '(650,2)'));
    final visibility = painter().visibility!;
    final note = painter().timeline.notes.singleWhere(
      (note) => note.kind == AffKind.arc,
    );
    expect(visibility.onlySelected, isTrue);
    expect(visibility.shows(note), isFalse);
    expect(visibility.shows(note, tap: 400), isTrue);
    expect(visibility.shows(note, tap: 1200), isFalse);
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final perspective =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartPerspectivePainter,
                  ),
                )
                .painter!
            as ChartPerspectivePainter;
    expect(perspective.visibility!.shows(note), isFalse);
    expect(perspective.visibility!.shows(note, tap: 400), isTrue);
    expect(perspective.visibility!.shows(note, tap: 1200), isFalse);
    await tester.tap(find.text('3D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示项'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('天键').last);
    await tester.tap(find.text('天键').last);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(painter().visibility!.shows(note, tap: 400), isFalse);
  });

  test('2D 和 3D 实际绘制同一选中天键，蛇内辅助线仅由编辑器绘制', () async {
    final timeline = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}arc(100,1500,0.3,0.3,s,0.8,0.8,0,none,false)'
        '[arctap(400),arctap(1200)];',
      ),
    );
    final isolated = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}arc(400,400,0.3,0.3,s,0.8,0.8,0,none,true)[arctap(400)];',
      ),
    );
    final note = timeline.notes.single;
    final cursor = ValueNotifier(0.0);
    addTearDown(cursor.dispose);
    const size = Size(800, 520);
    for (final perspective in [false, true]) {
      Future<Uint8List> render(
        ChartTimeline data,
        ChartEditorVisibility? visibility,
      ) async {
        final painter = perspective
            ? ChartPerspectivePainter(
                data,
                cursor,
                2100,
                editing: true,
                visibility: visibility,
              )
            : ChartTimelinePainter(data, cursor, 2100, visibility: visibility);
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        try {
          return (await image.toByteData())!.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      }

      final filtered = await render(
        timeline,
        ChartEditorVisibility(
          onlySelected: true,
          selection: {note},
          attachedTap: (note: note, tap: 400),
        ),
      );
      final expected = await render(
        isolated,
        ChartEditorVisibility(
          onlySelected: true,
          selection: {isolated.notes.single},
        ),
      );
      expect(
        listEquals(filtered, expected),
        isTrue,
        reason: '3D: $perspective',
      );
      final guide = await render(timeline, const ChartEditorVisibility());
      final withoutGuide = await render(
        timeline,
        ChartEditorVisibility(
          items: ChartDisplayItem.values
              .where((item) => item != ChartDisplayItem.trace)
              .toSet(),
        ),
      );
      expect(
        listEquals(guide, withoutGuide),
        isFalse,
        reason: '3D: $perspective',
      );
      expect(listEquals(await render(timeline, null), withoutGuide), isTrue);
    }
  });

  testWidgets('范围选择跳过隐藏类别，批量镜像后仍显示选中的音符', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}(100,1);(250,2);'
      'arc(100,250,0.1,0.3,s,1,1,0,none,false);',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示项'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, '蛇'));
    await tester.pump();
    await tester.tap(find.text('仅显示选中'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    Future<void> chooseOperation(String label) async {
      final operations = find.byTooltip('编辑选中的音符');
      await tester.ensureVisible(operations);
      await tester.tap(operations);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, label));
      await tester.pumpAndSettle();
    }

    await chooseOperation('范围选择…');
    await tester.tap(find.widgetWithText(FilledButton, '选择'));
    await tester.pumpAndSettle();
    await chooseOperation('水平镜像');
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter;
    expect(painter.visibility!.selection.map((note) => note.number(1)), [4, 3]);
    expect(
      painter.timeline.notes
          .singleWhere((note) => note.kind == AffKind.arc)
          .point(100)
          .x,
      0.1,
    );
  });

  test('移动跨类型接点时保持所有弧段相接并保护附着天键', () {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'arc(100,400,0.2,0.5,s,1,0.8,1,none,false)[arctap(370)];'
      'arc(400,900,0.5,0.8,b,0.8,1,0,none,true);'
      'arc(400,1200,0.5,0.9,s,0.8,1,2,none,false);'
      'timinggroup(noinput){arc(400,900,0.5,0.4,s,0.8,1,0,none,true);};',
    );
    final first = chart.events.firstWhere((note) => note.kind == AffKind.arc);
    final end = chartKeyframes(
      first,
    ).singleWhere((key) => key.kind == ChartKeyframeKind.end);
    expect(chartJoinedEndpoints(chart, end), hasLength(3));
    expect(moveChartKeyframe(chart, end, 0.6, 0.5, time: 350), chart.source);
    final edited = AffChart.parse(
      moveChartKeyframe(chart, end, 0.6, 0.5, time: 450),
    );
    expect(edited.errors, isEmpty);
    final arcs = edited.events
        .where((note) => note.kind == AffKind.arc)
        .toList();
    expect(
      arcs.take(3).map((arc) => arc.point(450)),
      List.filled(3, (x: 0.6, height: 0.5)),
    );
    expect(arcs.take(3).map((arc) => arc.trace), [false, true, false]);
    expect(arcs.first.arcTaps, [370]);
    expect(arcs.last.start, 400);
  });

  testWidgets('2D 拖动创建可吸附已有蛇端点，3D 移动时跨类型共同更新', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}arc(100,480,0.1,0.42375,s,1,0.73,0,none,false);',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('弧线'));
    await tester.pumpAndSettle();
    final flat = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    final bounds = tester.getRect(flat);
    final geometry = TimelineGeometry(bounds.size, 0, 2100);
    Offset at(double x, double time) =>
        bounds.topLeft +
        Offset(geometry.x(x, airborne: true), geometry.y(time));
    final stroke = await tester.startGesture(at(0.42375, 480).translate(4, 3));
    await stroke.moveTo(at(0.75, 1000));
    await stroke.up();
    await tester.pumpAndSettle();
    final notes =
        (tester.widget<CustomPaint>(flat).painter! as ChartTimelinePainter)
            .timeline
            .notes;
    expect(notes, hasLength(2));
    final trace = notes.singleWhere((note) => note.trace);
    expect(trace.start, 480);
    expect(trace.point(480), (x: 0.42375, height: 0.73));
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final perspective = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final frame = tester.getRect(perspective);
    final g = PerspectiveGeometry(frame.size, 0, 2100);
    await tester.dragFrom(
      frame.topLeft + g.projectAir(0.42375, 0.73, 480),
      const Offset(20, 10),
    );
    await tester.pumpAndSettle();
    final moved =
        (tester.widget<CustomPaint>(perspective).painter!
                as ChartPerspectivePainter)
            .timeline
            .notes;
    expect(moved.last.point(480), isNot(trace.point(480)));
    expect(moved.first.arguments[3], moved.last.arguments[2]);
    expect(moved.first.arguments[6], moved.last.arguments[5]);
  });

  testWidgets('3D 可把不同类型的独立端点吸附到同一时间、位置和高度', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}'
      'arc(100,480,0.1,0.25,s,1,0.73,1,none,false);'
      'arc(500,1200,0.55,0.75,s,0.81,1,2,none,true);',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final bounds = tester.getRect(canvas);
    final geometry = PerspectiveGeometry(bounds.size, 0, 2100);
    final start = bounds.topLeft + geometry.projectAir(0.25, 0.73, 480);
    final target = bounds.topLeft + geometry.projectAir(0.55, 0.81, 500);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(target.translate(-2, 1));
    await tester.pump();
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(painter.snapPoint, isNotNull);
    expect(
      (painter.snapPoint! - target + bounds.topLeft).distance,
      lessThan(1e-6),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final notes =
        (tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter)
            .timeline
            .notes;
    expect(notes.first.end, notes.last.start);
    expect(notes.first.arguments[3], notes.last.arguments[2]);
    expect(notes.first.arguments[6], notes.last.arguments[5]);
  });

  testWidgets('可以指定并断开重合的端点，拖动时另一弧段保持原位', (tester) async {
    const snake = 'arc(100,480,0.1,0.45,s,1,0.73,1,none,false);';
    const trace = 'arc(480,1200,0.45,0.75,s,0.73,1,2,none,true);';
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      AffChart.blank + snake + trace,
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    Offset junction() {
      final box = tester.getRect(canvas);
      return box.topLeft +
          PerspectiveGeometry(box.size, 0, 2100).projectAir(0.45, 0.73, 480);
    }

    await tester.tapAt(junction());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '断开拼接'));
    await tester.pumpAndSettle();
    expect(find.text('蛇 · 终点'), findsOneWidget);
    await tester.tap(find.text('弧线 · 起点'));
    await tester.pumpAndSettle();
    expect(find.text('取消断开'), findsOneWidget);
    await tester.tap(find.text('只调高度'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(junction());
    await gesture.moveBy(const Offset(0, 9));
    await tester.pump();
    final painting =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    expect(painting.snapPoint, isNull);
    await gesture.up();
    await tester.pumpAndSettle();
    final notes =
        (tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter)
            .timeline
            .notes;
    expect(notes.first.number(3), 0.45);
    expect(notes.first.number(6), 0.73);
    expect(notes.last.number(2), 0.45);
    expect(notes.last.number(5), isNot(0.73));
    expect(find.text('取消断开'), findsNothing);
  });

  test('Sky Input 覆盖同位置的高空键，停速长按仍可绘制', () async {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'timing(0,0,4);hold(100,900,2);'
      'arc(50,50,0.5,0.5,s,1,1,0,none,true)[arctap(50)];',
    );
    final position = ValueNotifier(0.0);
    addTearDown(position.dispose);
    final recorder = ui.PictureRecorder();
    const size = Size(800, 520);
    ChartPerspectivePainter(
      ChartTimeline(chart),
      position,
      2100,
    ).paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    addTearDown(picture.dispose);
    addTearDown(image.dispose);
    final pixels = (await image.toByteData())!;
    final g = PerspectiveGeometry(size, 0, 2100);
    final sky = g.projectAir(0.5, 1, 0);
    final row = sky.dy.round();
    final column = sky.dx.round();
    int component(int y, int channel) =>
        pixels.getUint8((y * size.width.toInt() + column) * 4 + channel);
    expect(
      [row - 1, row, row + 1].any(
        (y) =>
            component(y, 0) > 180 &&
            (component(y, 1) - component(y, 2)).abs() < 14 &&
            component(y, 2) > 120,
      ),
      isTrue,
      reason:
          'Sky Input pixels ${[
            for (final y in [row - 1, row, row + 1]) [component(y, 0), component(y, 1), component(y, 2)],
          ]}',
    );
    final hold = g.project(0.375, 0.038, g.noteDepth(9));
    final index = (hold.dy.round() * size.width.toInt() + hold.dx.round()) * 4;
    expect(
      pixels.getUint8(index + 1),
      greaterThan(pixels.getUint8(index) + 30),
    );
  });

  test('3D 空键键体收窄，2D 编辑、预览和试玩沿同一判定时间加长空键', () async {
    const size = Size(800, 520);
    final cursor = ValueNotifier(0.0);
    addTearDown(cursor.dispose);
    final blank = ChartTimeline(AffChart.parse(AffChart.blank));
    final withTap = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}arc(300,300,0.5,0.5,s,0.7,0.7,0,none,true)[arctap(300)];',
      ),
    );
    Future<ByteData> render(CustomPainter painter) async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      try {
        return (await image.toByteData())!;
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    int pixel(ByteData image, Offset sample) => image.getUint32(
      (sample.dy.round() * size.width.toInt() + sample.dx.round()) * 4,
    );
    final g = PerspectiveGeometry(size, 0, 2100);
    for (final editing in [true, false]) {
      final background = await render(
        ChartPerspectivePainter(blank, cursor, 2100, editing: editing),
      );
      final chart = await render(
        ChartPerspectivePainter(withTap, cursor, 2100, editing: editing),
      );
      for (final side in [-1, 1]) {
        final inside = g.projectArcTap(
          0.5 + side * 0.18,
          0.7,
          300,
          modelHeight: 0.3,
        );
        final outside = g.projectArcTap(
          0.5 + side * 0.33,
          0.7,
          300,
          modelHeight: 0.3,
        );
        expect(pixel(chart, inside), isNot(pixel(background, inside)));
        expect(pixel(chart, outside), pixel(background, outside));
      }
    }
    for (final overlay in [false, true]) {
      final flat = TimelineGeometry(size, 0, 2100, overlay: overlay);
      final bounds = flat.arcTapBounds(0.5, 0.7, 300);
      expect(bounds.center.dy, flat.y(300));
      expect(bounds.width, greaterThan(24));
      final chord = ChartTimeline(
        AffChart.parse(
          '${AffChart.blank}arc(300,300,0.35,0.35,s,0.7,0.7,0,none,true)[arctap(300)];'
          'arc(300,300,0.5,0.5,s,0.7,0.7,0,none,true)[arctap(300)];',
        ),
      );
      expect(flat.nearest(chord, bounds.center)?.point(300).x, 0.5);
      for (final mode in [0, 1, 2]) {
        final blankPixels = await render(
          ChartTimelinePainter(
            blank,
            cursor,
            2100,
            preview: mode > 0,
            overlay: overlay,
            judgement: mode == 2 ? ChartJudgement() : null,
          ),
        );
        final notePixels = await render(
          ChartTimelinePainter(
            withTap,
            cursor,
            2100,
            preview: mode > 0,
            overlay: overlay,
            judgement: mode == 2 ? ChartJudgement() : null,
          ),
        );
        for (final x in [bounds.left + 3, bounds.right - 3]) {
          final sample = Offset(x, bounds.center.dy);
          expect(pixel(notePixels, sample), isNot(pixel(blankPixels, sample)));
          expect(flat.nearest(withTap, sample), withTap.notes.single);
        }
      }
    }
  });

  test('背向镜头的弧线被裁切，滑键方向不随向量长度改变', () async {
    const size = Size(800, 520);
    final geometry = PerspectiveGeometry(size, 0, 2100);
    final cursor = ValueNotifier(0.0);
    addTearDown(cursor.dispose);
    final note =
        'timinggroup(anglex1800){arc(1100,1900,0,1,s,0.2,0.8,0,none,false);};';
    final chart = AffChart.parse(AffChart.blank + note);
    expect(chart.errors, isEmpty);
    Future<ByteData> render(AffChart chart) async {
      final recorder = ui.PictureRecorder();
      ChartPerspectivePainter(
        ChartTimeline(chart),
        cursor,
        2100,
      ).paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      try {
        return (await image.toByteData())!;
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    final blank = AffChart.parse(AffChart.blank);
    expect(
      (await render(chart)).buffer.asUint8List(),
      (await render(blank)).buffer.asUint8List(),
    );
    cursor.value = 1100;
    final nowVisible = (await render(chart)).buffer.asUint8List();
    final empty = (await render(blank)).buffer.asUint8List();
    expect(
      nowVisible.indexed.any((entry) => entry.$2 != empty[entry.$1]),
      isTrue,
    );
    final a = geometry.flickDirection(1.25, 1, 600, const Offset(1, 2));
    final b = geometry.flickDirection(
      1.25,
      1,
      600,
      const Offset(50000, 100000),
    );
    expect(a, b);
    expect(geometry.flickArrowLength(1.25, 1, 600), lessThanOrEqualTo(20));
  });

  testWidgets('四个跳转按钮应用自定义步长并在暂停时保持暂停', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(60000,1);');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: false,
          initial: 20000,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('前进 15 秒'));
    await tester.pumpAndSettle();
    expect(find.text('35.00 s'), findsOneWidget);
    await tester.tap(find.byTooltip('设置自定义跳转秒数'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '2.5');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('后退自定义秒数'));
    await tester.pumpAndSettle();
    expect(find.text('32.50 s'), findsOneWidget);
    await tester.tap(find.byTooltip('前进自定义秒数'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('后退 15 秒'));
    await tester.pumpAndSettle();
    expect(find.text('20.00 s'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'chart_preview_jump_seconds',
      ),
      2.5,
    );
  });

  testWidgets('2D 天键按放宽后的半宽判定，命中当帧隐藏并保留特效', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(80,80,0.5,0.5,s,0.6,0.6,0,none,true)[arctap(80)];',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final geom = TimelineGeometry(tester.getSize(canvas), 0, 2100);
    final topLeft = tester.getTopLeft(canvas);
    final key = geom.arcTapBounds(0.5, 0.6, 0);
    final edge = topLeft + key.center + Offset(0, key.width * 0.69);
    await tester.tapAt(
      topLeft + key.center + Offset(key.width * 0.56, key.width * 0.56),
    );
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 0);
    await tester.tapAt(edge);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 1);
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter;
    expect(
      painter.judgement!.hidden(
        painter.timeline.notes.single,
        painter.position.value,
        tap: 80,
      ),
      isTrue,
    );
    expect(painter.judgement!.hitEffects, hasLength(1));
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('3D 播放投影放大并使 4K／6K 的轨道近端贴齐画布底边', () {
    final timeline = ChartTimeline(AffChart.parse(AffChart.blank));
    for (final size in [const Size(850, 520), const Size(390, 610)]) {
      final normal = PerspectiveGeometry(size, 0, 2100);
      for (final mode in [ChartLaneMode.four, ChartLaneMode.six]) {
        final g = PerspectiveGeometry.forPlayback(
          size,
          0,
          2100,
          timeline,
          mode,
        );
        final expanded = mode == ChartLaneMode.six;
        final left = g.project(expanded ? -.25 : 0, 0, g.near);
        final right = g.project(expanded ? 1.25 : 1, 0, g.near);
        expect(left.dx, greaterThan(0));
        expect(right.dx, lessThan(size.width));
        expect(left.dy, closeTo(size.height, 1e-8));
        expect(right.dy, closeTo(size.height, 1e-8));
        if (!expanded) expect(g.width, greaterThan(normal.width));
      }
    }
  });

  testWidgets('两指接住蛇和长按时第三指仍能在天空线上方点击天键', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}'
      'hold(-200,1500,1);'
      'arc(-200,1500,0.2,0.2,s,0.7,0.7,1,none,false);'
      'arc(0,0,0.8,0.8,s,1,1,0,none,true)[arctap(0)];',
    );
    final sustained = raw.events.where((note) => note.isSustain);
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        for (final note in sustained) note: [0],
      }),
    );
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    await _startPlayback(tester);
    final box = tester.getRect(canvas);
    final g = PerspectiveGeometry.forPlayback(
      box.size,
      0,
      2100,
      timeline,
      ChartLaneMode.automatic,
    );
    final note = g.projectArcTap(.8, 1, 0);
    final skyLine = g.projectAir(.8, 1, 0);
    final radius =
        (g.projectArcTap(.8 + PerspectiveGeometry.arcTapHalfWidth, 1, 0) - note)
            .distance;
    final above = note.translate(0, -radius * 1.18);
    expect(above.dy, lessThan(skyLine.dy));
    expect(above.dy, greaterThan(0));
    final hold = await tester.startGesture(
      box.topLeft + g.project(.125, 0, 0),
      pointer: 41,
    );
    final snake = await tester.startGesture(
      box.topLeft + g.projectAir(.2, .7, 0),
      pointer: 42,
    );
    await tester.pump(const Duration(milliseconds: 16));
    elapsed = 4;
    final third = await tester.startGesture(box.topLeft + above, pointer: 43);
    await tester.pump();
    final report =
        tester.widget<CustomPaint>(canvas).foregroundPainter!
            as PracticeFeedbackPainter;
    expect(
      report.judgements.history.map((hit) => hit.key),
      unorderedEquals([PracticeKey.hold, PracticeKey.snake, PracticeKey.air]),
    );
    await third.up();
    await snake.up();
    await hold.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('重叠的地键和天键选择时间更准的键', (tester) async {
    SharedPreferences.setMockInitialValues({
      'chart_preview_overlay': true,
      'chart_practice_transition': false,
    });
    final chart = AffChart.parse(
      '${AffChart.blank}(46,2);'
      'arc(0,0,0.5,0.5,s,1,1,0,none,true)[arctap(0)];',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final box = tester.getRect(canvas);
    final g = TimelineGeometry(box.size, 0, 2100, overlay: true);
    await tester.tapAt(box.topLeft + Offset(g.x(.375), g.judgement));
    await tester.pump();
    final report =
        tester.widget<CustomPaint>(canvas).foregroundPainter!
            as PracticeFeedbackPainter;
    expect(report.judgements.history.single.key, PracticeKey.air);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('重叠天键双押按同帧触点匹配，避免先到触点占错键', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'arc(0,0,0.25,0.25,s,1,1,0,none,true)[arctap(0)];'
      'arc(0,0,0.51,0.51,s,1,1,0,none,true)[arctap(0)];',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final bounds = tester.getRect(canvas);
    final plane = TimelineGeometry(bounds.size, 0, 2100);
    Offset at(double x) =>
        bounds.topLeft + Offset(plane.x(x, airborne: true), plane.judgement);
    final overlapping = await tester.startGesture(at(0.36), pointer: 21);
    final left = await tester.startGesture(at(0.1), pointer: 22);
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 2);
    await overlapping.up();
    await left.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('同帧双押优先匹配可得分的天键，避免 LOST 占用触点', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'arc(0,0,0.10,0.10,s,1,1,0,none,true)[arctap(0)];'
      'arc(109,109,0.27,0.27,s,1,1,0,none,true)[arctap(109)];'
      'arc(109,109,0.245,0.245,s,1,1,0,none,true)[arctap(109)];',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 109,
          practice: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final bounds = tester.getRect(canvas);
    final plane = TimelineGeometry(bounds.size, 109, 2100);
    Offset at(double x) =>
        bounds.topLeft + Offset(plane.x(x, airborne: true), plane.judgement);
    final left = await tester.startGesture(at(.125), pointer: 31);
    final overlapping = await tester.startGesture(at(.36), pointer: 32);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 2);
    await left.up();
    await overlapping.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('透明度分别保存并同步到 2D、3D 和试玩', (tester) async {
    final chart = AffChart.parse(AffChart.blank);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('谱面不透明度'));
    await tester.pumpAndSettle();
    for (final (name, opacity) in [('天键', 0.2), ('蛇', 0.5), ('弧线', 0.8)]) {
      tester.widget<Slider>(find.byKey(ValueKey(name))).onChanged!(opacity);
    }
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    const expected = (arcTap: 0.2, snake: 0.5, trace: 0.8);
    final perspective =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartPerspectivePainter,
                  ),
                )
                .painter!
            as ChartPerspectivePainter;
    expect(perspective.appearance, expected);
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final flat =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartTimelinePainter,
                  ),
                )
                .painter!
            as ChartTimelinePainter;
    expect(flat.appearance, expected);
    expect(
      savedChartAppearance(await SharedPreferences.getInstance()),
      expected,
    );
  });

  testWidgets('窄屏编辑、预览和试玩都有文字透明度入口，并共用设置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();

    Future<void> checkAndSet(double initial, double next) async {
      final entry = find.text('透明度');
      expect(entry.hitTestable(), findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('天键'));
      expect(tester.widget<Slider>(slider).value, initial);
      tester.widget<Slider>(slider).onChanged!(next);
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
    }

    await checkAndSet(1, 0.6);
    for (final (mode, initial, next) in [('预览', 0.6, 0.4), ('试玩', 0.4, 0.2)]) {
      await tester.tap(find.text(mode));
      await tester.pumpAndSettle();
      await checkAndSet(initial, next);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await checkAndSet(0.2, 0.8);
    expect(
      savedChartAppearance(await SharedPreferences.getInstance()).arcTap,
      0.8,
    );
  });

  test('两种渲染分别控制蛇体、辅助弧线和天键透明度', () async {
    final chart = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}'
        'arc(400,1200,0.2,0.2,s,0.45,0.45,0,none,false);'
        'arc(400,1200,0.65,0.65,s,0.8,0.8,0,none,true)[arctap(800)];',
      ),
    );
    final blank = ChartTimeline(AffChart.parse(AffChart.blank));
    final cursor = ValueNotifier(0.0);
    addTearDown(cursor.dispose);
    const size = Size(800, 520);
    Future<ByteData> render(CustomPainter painter) async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      try {
        return (await image.toByteData())!;
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    bool matches(ByteData first, ByteData second) {
      final a = first.buffer.asUint32List(), b = second.buffer.asUint32List();
      return a.indexed.every((entry) => entry.$2 == b[entry.$1]);
    }

    for (final perspective in [false, true]) {
      CustomPainter paint(ChartTimeline timeline, ChartAppearance appearance) =>
          perspective
          ? ChartPerspectivePainter(
              timeline,
              cursor,
              2100,
              appearance: appearance,
            )
          : ChartTimelinePainter(
              timeline,
              cursor,
              2100,
              preview: true,
              appearance: appearance,
            );
      final noNotes = await render(paint(blank, defaultChartAppearance));
      final hidden = await render(
        paint(chart, (arcTap: 0, snake: 0, trace: 0)),
      );
      expect(matches(noNotes, hidden), isTrue);
      final visible = [
        for (final appearance in [
          (arcTap: 1.0, snake: 0.0, trace: 0.0),
          (arcTap: 0.0, snake: 1.0, trace: 0.0),
          (arcTap: 0.0, snake: 0.0, trace: 1.0),
        ])
          await render(paint(chart, appearance)),
      ];
      expect(visible.every((pixels) => !matches(noNotes, pixels)), isTrue);
      expect(matches(visible[0], visible[1]), isFalse);
      expect(matches(visible[1], visible[2]), isFalse);
    }
  });

  testWidgets('只有预览响应双指双击，试玩继续播放且空格仍可暂停', (tester) async {
    final chart = AffChart.parse(AffChart.blank);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byTooltip('暂停'), findsOneWidget);
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    Future<void> doubleTap(int start) async {
      final center = tester.getCenter(canvas);
      for (var tap = 0; tap < 2; tap++) {
        final stamp = Duration(milliseconds: start + tap * 240);
        for (var i = 0; i < 2; i++) {
          await tester.sendEventToBinding(
            PointerDownEvent(
              pointer: i + 100,
              timeStamp: stamp,
              position: center + Offset(30.0 * i, 0),
            ),
          );
        }
        for (var i = 0; i < 2; i++) {
          await tester.sendEventToBinding(
            PointerUpEvent(
              pointer: i + 100,
              timeStamp: stamp + const Duration(milliseconds: 75),
              position: center + Offset(30.0 * i, 0),
            ),
          );
        }
        await tester.pump();
      }
    }

    await doubleTap(100);
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅预览'));
    await tester.pump();
    await _startPlayback(tester);
    await doubleTap(600);
    expect(find.byTooltip('播放'), findsOneWidget);
    await doubleTap(1200);
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  testWidgets('6K 两侧地键命中当帧隐藏，独立播放特效并保留漏击', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(0,0);(0,5);(0,2);');
    final timeline = ChartTimeline(chart);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
          laneMode: ChartLaneMode.six,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 2);
    final canvas = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartPerspectivePainter,
      ),
    );
    final painter = canvas.painter! as ChartPerspectivePainter;
    final judgement = painter.judgement!;
    expect(judgement.hitEffects, hasLength(2));
    final current = painter.position.value;
    final end = judgement.hitEffects.last.at + ChartJudgement.duration + 1;
    for (final note in timeline.notes) {
      expect(judgement.hidden(note, current), note.laneX < 0 || note.laneX > 1);
      expect(judgement.hidden(note, end), note.laneX < 0 || note.laneX > 1);
    }
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('持续按住只裁切已按住的长按区段，松开后的间隙可保留', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}hold(0,2500,2);hold(0,2600,2);hold(0,2500,3);',
    );
    final timeline = ChartTimeline(chart);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    final judgement = painter.judgement!;
    final hold = timeline.notes.singleWhere(
      (note) => note.laneX < 0.5 && note.end == 2500,
    );
    final overlapping = timeline.notes.singleWhere((note) => note.end == 2600);
    final missed = timeline.notes.singleWhere((note) => note.laneX > 0.5);
    Future<void> playFor(Duration duration) async {
      await tester.runAsync(() => Future<void>.delayed(duration));
      await tester.pump(duration);
    }

    await playFor(const Duration(milliseconds: 85));
    final firstSample = painter.position.value;
    expect(
      judgement.visibleSustain(hold, firstSample - 20, firstSample - 1),
      isEmpty,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await playFor(const Duration(milliseconds: 100));
    final beforeResume = painter.position.value;
    expect(
      judgement.visibleSustain(hold, beforeResume - 20, beforeResume - 1),
      [(start: beforeResume - 20, end: beforeResume - 1)],
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await playFor(const Duration(milliseconds: 85));
    final secondSample = painter.position.value;
    expect(
      judgement.visibleSustain(hold, secondSample - 20, secondSample - 1),
      isEmpty,
    );
    expect(
      judgement.visibleSustain(hold, beforeResume - 20, beforeResume - 1),
      [(start: beforeResume - 20, end: beforeResume - 1)],
    );
    expect(judgement.visibleSustain(missed, 0, 2500), [
      (start: 0.0, end: 2500.0),
    ]);
    expect(judgement.visibleSustain(overlapping, 0, 2600), [
      (start: 0.0, end: 2600.0),
    ]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('4K 和 6K 保持 AFF 键道坐标，停速时只允许编辑当前时间的空键', () {
    final chart = AffChart.parse(
      '${AffChart.blank}'
      'timing(50,0,4);(80,0);(80,5);arc(100,100,0.5,0.5,s,1,1,0,none,true)[arctap(100)];',
    );
    final timeline = ChartTimeline(chart);
    final arc = timeline.notes.singleWhere((note) => note.isAir);
    expect(ChartLaneMode.four.expansion(timeline, 100), 0);
    expect(ChartLaneMode.six.expansion(timeline, 100), 1);
    expect(timeline.notes.where(ChartLaneMode.four.shows), [arc]);
    expect(timeline.notes.where(ChartLaneMode.six.shows), hasLength(3));
    expect(timeline.onJudgementPlane(arc, 80, 100, 2), isFalse);
    expect(timeline.onJudgementPlane(arc, 100, 100, 2), isTrue);
  });

  test('3D 轨道和空键投影可反算落点，2D 叠加共用宽度和时间', () {
    for (final size in [const Size(1000, 550), const Size(380, 780)]) {
      final g = PerspectiveGeometry(size, 500, 2100);
      final air = g.pick(g.projectAir(0.75, 0.65, 500), air: true)!;
      final tap = g.pick(
        g.projectArcTap(0.75, 0.65, 500),
        air: true,
        arcTap: true,
      )!;
      expect(tap.x, closeTo(0.75, 1e-9));
      expect(tap.height, closeTo(0.65, 1e-9));
      expect(g.projectAir(-0.25, 1, 500).dx, greaterThan(0));
      expect(g.projectAir(1.25, 1, 500).dx, lessThan(size.width));
      final tapLeft = g.projectArcTap(
        0.5 - PerspectiveGeometry.arcTapHalfWidth,
        1,
        500,
      );
      final tapRight = g.projectArcTap(
        0.5 + PerspectiveGeometry.arcTapHalfWidth,
        1,
        500,
      );
      expect(
        (tapRight.dx - tapLeft.dx) / g.width,
        inInclusiveRange(0.26, 0.31),
      );
      expect(
        (g.projectAir(1, 1, 500).dx - g.projectAir(0, 1, 500).dx) / g.width,
        lessThan(0.64),
      );
      expect(g.arcTapDistance(tapLeft, 0.5, 1), closeTo(0, 1e-7));
      expect(air.x, closeTo(0.75, 1e-9));
      expect(air.height, closeTo(0.65, 1e-9));
      final ground = g.pick(g.project(0.375, 0, 1050), air: false)!;
      expect(ground.x, closeTo(0.375, 1e-9));
      expect(ground.depth, closeTo(1050, 1e-9));
      final overlay = TimelineGeometry(
        size,
        500,
        2100,
        overlay: true,
        wideLanes: true,
      );
      for (final x in [-0.25, 0.125, 0.5, 1.25]) {
        expect(overlay.x(x), overlay.x(x, airborne: true));
      }
      expect(overlay.y(500), overlay.judgement);
      final split = TimelineGeometry(size, 500, 2100);
      expect(
        split.arcTapBounds(1.5, 1, 500).right,
        lessThanOrEqualTo(size.width + 1e-6),
      );
    }
  });

  test('关键点生成连续 AFF 弧段，接点上的空键只出现一次', () {
    final draft = ArcDraft(
      points: [
        (time: 500, x: 0.0, height: 0.5),
        (time: 750, x: 0.5, height: 1.0),
        (time: 1000, x: 0.75, height: 0.7),
      ],
      trace: true,
      taps: {500, 750, 950, 1000},
      segments: {500: 'siso'},
    );
    final chart = AffChart.parse(AffChart.blank + draft.encode().join('\n'));
    expect(chart.errors, isEmpty);
    final events = chart.events.where((event) => event.isAir).toList();
    expect(events[0].arcTaps, [500]);
    expect(events[1].arcTaps, [750, 950, 1000]);
    final restored = ArcDraft.fromEvents(
      ArcDraft.connected(chart, events.last),
    );
    expect(restored.points, draft.points);
    expect(restored.taps, draft.taps);
    expect(restored.segments[500], 'siso');
    final existing = AffChart.parse(
      '${AffChart.blank}'
      'arc(0,500,0,0.5,s,1,1,0,none,true)[arctap(500)];\n'
      'arc(500,800,0.5,1,s,1,1,0,none,true)[arctap(500)];',
    );
    final original = existing.events.where((event) => event.isAir).toList();
    final chain = ArcDraft.fromEvents(original);
    chain.points[1] = (time: 500, x: 0.6, height: 1.0);
    expect(
      chain.encode().where((line) => line.contains('[arctap(500)]')),
      hasLength(2),
    );
  });

  test('节拍网格以分组 BPM 定位，跨变速点并支持小数和负时间', () {
    final timeline = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}timing(620,180,4);timing(1500,0,4);'
        'timinggroup(){timing(0,240,4);};',
      ),
    );
    final grid = ChartBeatGrid(timeline.tempos, subdivision: 16, bpmBase: 120);
    expect(grid.next(-125, forward: false), -250);
    expect(grid.next(-125, forward: true), 0);
    expect(grid.next(500, forward: true), 620);
    expect(grid.next(620, forward: false), 500);
    expect(grid.next(620, forward: true), 703);
    expect(grid.next(703, forward: true), 787);
    expect(grid.next(787, forward: false), 703);
    expect(grid.next(1500, forward: true), 1537);
    final dense = ChartBeatGrid([], subdivision: 64, bpmBase: 1e100);
    expect(dense.next(500, forward: true), 501);
    final group = ChartBeatGrid(
      timeline.groupTempos(1),
      subdivision: 16,
      bpmBase: 120,
    );
    expect(group.next(0, forward: true), 63);
  });

  testWidgets('滚轮与双指按可调节拍细分移动游标，手势不放置音符', (tester) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1000, 750);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const channel = MethodChannel('arcaea_manager/chart_input');
    final binary =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binary.setMockMethodCallHandler(channel, (_) async => 200.0);
    addTearDown(() => binary.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('地键'));
    final painter = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    final center = tester.getCenter(painter);
    Future<void> wheel(double dy) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: Offset(0, dy / tester.view.devicePixelRatio),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
    }

    final position =
        (tester.widget<CustomPaint>(painter).painter! as ChartTimelinePainter)
            .position;
    await wheel(200);
    expect(position.value, 125);
    await tester.tap(find.byTooltip('节拍细分与滚动步长'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, '1/8'));
    await tester.pumpAndSettle();
    await wheel(200);
    expect(position.value, 250);
    if (Platform.isWindows) {
      await wheel(400);
      expect(position.value, 750);
      await wheel(-400);
      expect(position.value, 250);
    }
    final first = await tester.startGesture(center - const Offset(24, 0));
    final second = await tester.startGesture(center + const Offset(24, 0));
    await first.moveBy(const Offset(0, -23));
    await second.moveBy(const Offset(0, -23));
    expect(position.value, 250);
    await first.moveBy(const Offset(0, -1));
    await second.moveBy(const Offset(0, -1));
    expect(position.value, 0);
    await first.up();
    await second.up();
    await tester.pump();
    final left = await tester.startGesture(center - const Offset(25, 0));
    final right = await tester.startGesture(center + const Offset(25, 0));
    await left.moveBy(const Offset(-25, 0));
    await right.moveBy(const Offset(25, 0));
    await left.up();
    await right.up();
    await tester.pump();
    expect(position.value, 0);
    expect(
      tester.widget<CustomPaint>(painter).painter,
      isA<ChartTimelinePainter>(),
    );
    expect(
      (tester.widget<CustomPaint>(painter).painter! as ChartTimelinePainter)
          .lookahead,
      1050,
    );
    final anchor = await tester.startGesture(center - const Offset(25, 0));
    final moving = await tester.startGesture(center + const Offset(25, 0));
    await moving.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await anchor.up();
    await moving.up();
    await tester.pump();
    expect(
      (tester.widget<CustomPaint>(painter).painter! as ChartTimelinePainter)
          .lookahead,
      700,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await wheel(-200);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(position.value, 0);
    expect(
      (tester.widget<CustomPaint>(painter).painter! as ChartTimelinePainter)
          .lookahead,
      lessThan(700),
    );
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置铺面缩放'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1.5');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final space =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ChartPerspectivePainter,
                  ),
                )
                .painter!
            as ChartPerspectivePainter;
    expect(space.lookahead, 1400);
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('aff-source')))
          .controller!
          .text,
      AffChart.blank,
    );
  });

  testWidgets('预览音量即时下发并保存，2D 可叠加后进入练习', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    final channel = const MethodChannel('arcaea_manager/chart_audio');
    final gains = <double>[];
    final binary =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binary.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'volume') {
        gains.add((call.arguments as Map)['gain'] as double);
      }
      return call.method == 'open' ? 10000 : null;
    });
    addTearDown(() => binary.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({'chart_music_volume': 0.4});
    final chart = AffChart.parse(AffChart.blank);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: false,
          audio: () async => {'file': 'fixture.ogg'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(gains, [0.4]);
    await tester.tap(find.byTooltip('音乐音量'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('静音'));
    await tester.pumpAndSettle();
    expect(gains.last, 0);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getDouble('chart_music_volume'),
      0,
    );
    await tester.tap(find.byTooltip('音乐音量'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消静音'));
    await tester.pumpAndSettle();
    expect(gains.last, 0.4);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('叠加地键和空键'));
    await tester.tap(find.text('开始练习'));
    await tester.pumpAndSettle();
    expect(find.text('谱面试玩'), findsOneWidget);
    expect(find.byTooltip('设为循环起点'), findsOneWidget);
  });

  testWidgets('3D 空轨网格落键写入当前高度与时间', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空键'));
    await tester.pumpAndSettle();
    final painter = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final bounds = tester.getRect(painter);
    final geometry = PerspectiveGeometry(bounds.size, 0, 2100);
    await tester.tapAt(bounds.topLeft + geometry.projectArcTap(0.75, 0.5, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    final source = tester
        .widget<TextField>(find.byKey(const ValueKey('aff-source')))
        .controller!
        .text;
    final note = AffChart.parse(
      source,
    ).events.singleWhere((event) => event.isAir);
    expect(note.start, 0);
    expect(note.point(0), (x: 0.75, height: 0.5));
  });

  testWidgets('允许越界能把地键放在轨道间，并在 3D 把天键放到天空线上方', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许越界'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('地键'));
    await tester.pumpAndSettle();
    final flat = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(flat);
    final plane = TimelineGeometry(box.size, 0, 2100);
    await tester.tapAt(box.topLeft + Offset(plane.x(.25), plane.y(250)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('长按'));
    await tester.pumpAndSettle();
    await tester.dragFrom(
      box.topLeft + Offset(plane.x(-.12), plane.y(250)),
      Offset(0, plane.y(750) - plane.y(250)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D 编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空键'));
    await tester.pumpAndSettle();
    final space = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartPerspectivePainter,
    );
    final volume = tester.getRect(space);
    final geometry = PerspectiveGeometry(volume.size, 0, 2100);
    await tester.tapAt(volume.topLeft + geometry.projectArcTap(.5, 1.2, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    final source = tester
        .widget<TextField>(find.byKey(const ValueKey('aff-source')))
        .controller!
        .text;
    final chart = AffChart.parse(source);
    expect(chart.errors, isEmpty);
    expect(
      chart.events.singleWhere((note) => note.kind == AffKind.tap).laneX,
      .25,
    );
    expect(
      chart.events.singleWhere((note) => note.kind == AffKind.hold).laneX,
      -.12,
    );
    expect(
      chart.events.singleWhere((note) => note.kind == AffKind.arc).number(5),
      1.2,
    );
  });

  test('游标跳转重算镜头、轨道和分组显示，且保留变宽空键', () {
    final chart = AffChart.parse('''${AffChart.blank}
camera(1000,1000,0,0,0,0,0,l,1000);
camera(2100,0,0,0,0,0,0,reset,100);
scenecontrol(500,trackhide);
scenecontrol(1000,trackdisplay,500,255);
timinggroup(noinput_anglex900_fadingholds){
  scenecontrol(1000,hidegroup,0,1);
  scenecontrol(1750,hidegroup,0,0);
  arc(1100,1100,0.1,0.8,s,1,1,3,none,false);
}
(1500,5);
''');
    expect(chart.errors, isEmpty);
    expect(chart.unrendered, isEmpty);
    final timeline = ChartTimeline(chart);
    expect(timeline.groupOptions[1]!.angleX, 90);
    expect(timeline.groupOptions[1]!.fadingHolds, isTrue);
    expect(timeline.wideLanes, isTrue);
    expect(timeline.notes.first.variableArcTap, isTrue);
    expect(timeline.notes.first.noInput, isTrue);
    final scene = timeline.scene;
    expect(scene.track(1250), 0.5);
    expect(scene.groupOpacity(1, 1500), 0);
    expect(scene.groupOpacity(1, 1800), 1);
    expect(scene.camera(2150).x, 500);
    expect(scene.camera(1500).x, 500);
    expect(scene.camera(0).x, 0);
    final geometry = PerspectiveGeometry.forScene(
      const Size(800, 600),
      1500,
      2100,
      scene,
    );
    expect(geometry.project(0.5, 0, 1500).dx, lessThan(400));
    final edited = AffChart.parse(
      chart.changeGroupAttributes(chart.groups[1], 'angley2700'),
    );
    expect(edited.errors, isEmpty);
    expect(ChartTimeline(edited).groupOptions[1]!.angleY, 270);
    expect(edited.events.where((event) => event.isNote).first.noInput, isFalse);
  });

  test('分组流速分段累积，支持停止、倒流和变更基准 BPM', () {
    const source =
        'AudioOffset:0\n-\n'
        'timing(0,120,4);timing(100,240,4);timing(200,0,0);'
        'timing(300,-120,4);timing(400,120,4);\n'
        'timinggroup(){timing(0,60,4);(250,1);}\n';
    final aff = AffChart.parse(source);
    expect(aff.errors, isEmpty);
    final chart = ChartTimeline(aff, bpmBase: 120);
    final main = chart.scroll(0);
    expect(
      [main.at(100), main.at(200), main.at(300), main.at(400)],
      [100, 300, 300, 200],
    );
    expect(chart.scroll(1).at(250), 125);
    expect(ChartTimeline(aff, bpmBase: 60).scroll(1).at(250), 250);
    final ranges = main.visible(240, 260, 0, 400).toList();
    expect(ranges, [(start: 170.0, end: 180.0), (start: 340.0, end: 360.0)]);
    final edited = AffChart.parse(aff.appendToGroup(1, 'timing(80,-240,4);'));
    expect(edited.errors, isEmpty);
    expect(edited.events.singleWhere((event) => event.start == 80).group, 1);
  });

  test('难度素材覆盖曲目素材，两种渲染均应用背景和轨道贴图', () async {
    final dir = await Directory.systemTemp.createTemp('chartskin-');
    addTearDown(() => dir.delete(recursive: true));
    final folder = ArcStorage(dir.path);
    Future<Uint8List> png(Color color) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(color, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      picture.dispose();
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    }

    await folder.write('bg.png', await png(const Color(0xFF0022FF)));
    await folder.write('custom.png', await png(const Color(0xFFFF2200)));
    await folder.write('track.png', await png(const Color(0xFF00FF00)));
    await folder.write(
      '4.skin.json',
      Uint8List.fromList(utf8.encode('{"background":"custom.png"}')),
    );
    final skin = await ChartSkin.load(folder: folder, chartKey: '4');
    expect(skin[ChartSprite.background], isNotNull);
    expect(skin[ChartSprite.track], isNotNull);
    expect(skin[ChartSprite.tap], isNull);
    final timeline = ChartTimeline(AffChart.parse(AffChart.blank));
    final position = ValueNotifier(750.0);
    for (final painter in <CustomPainter>[
      ChartTimelinePainter(timeline, position, 2100, skin: skin),
      ChartPerspectivePainter(timeline, position, 2100, skin: skin),
    ]) {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(200, 300));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 300);
      final bytes = (await image.toByteData())!;
      int component(int x, int y, int channel) =>
          bytes.getUint8((y * 200 + x) * 4 + channel);
      expect(component(2, 2, 0), greaterThan(component(2, 2, 2)));
      final point = painter is ChartTimelinePainter
          ? const Offset(36, 225)
          : PerspectiveGeometry(
              Size(200, 300),
              750,
              2100,
            ).project(0.62, 0, 900);
      expect(
        component(point.dx.round(), point.dy.round(), 1),
        greaterThan(component(point.dx.round(), point.dy.round(), 0)),
      );
      image.dispose();
      picture.dispose();
    }
    position.dispose();
    skin.dispose();
  });

  test('蛇体贴图在 2D 和 3D 使用独立的左右手颜色和加宽的网格', () async {
    final dir = await Directory.systemTemp.createTemp('snake-palette-');
    final folder = ArcStorage(dir.path);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final texture = picture.toImageSync(16, 16);
    final data = (await texture.toByteData(format: ui.ImageByteFormat.png))!;
    await folder.write(
      'arc_body.png',
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    addTearDown(() async {
      await File('${dir.path}/arc_body.png').delete();
      await dir.delete();
    });
    texture.dispose();
    picture.dispose();
    final skin = await ChartSkin.load(folder: folder);
    addTearDown(skin.dispose);
    expect(skin.snakeTexture(0), isNotNull);
    expect(skin.snakeTexture(1, shaded: true), isNotNull);
    final timeline = ChartTimeline(
      AffChart.parse(
        '${AffChart.blank}'
        'arc(0,1500,0.15,0.15,s,0.6,0.6,0,none,false);'
        'arc(0,1500,0.85,0.85,s,0.6,0.6,1,none,false);',
      ),
    );
    const size = Size(720, 520);
    final cursor = ValueNotifier(200.0);
    addTearDown(cursor.dispose);
    final flat = TimelineGeometry(size, cursor.value, 2100);
    final perspective = PerspectiveGeometry(size, cursor.value, 2100);
    for (final (painter, sample) in <(CustomPainter, Offset Function(double))>[
      (
        ChartTimelinePainter(timeline, cursor, 2100, skin: skin),
        (x) => Offset(flat.x(x + 0.079, airborne: true), flat.y(550)),
      ),
      (
        ChartPerspectivePainter(timeline, cursor, 2100, skin: skin),
        (x) => perspective.projectAir(x + 0.079, 0.55, 550),
      ),
    ]) {
      final scene = ui.PictureRecorder();
      painter.paint(Canvas(scene), size);
      final frame = scene.endRecording();
      final image = frame.toImageSync(720, 520);
      try {
        final pixels = (await image.toByteData())!;
        for (final (x, blue) in [(0.15, true), (0.85, false)]) {
          final point = sample(x);
          final i = (point.dy.round() * 720 + point.dx.round()) * 4;
          final r = pixels.getUint8(i), b = pixels.getUint8(i + 2);
          expect(
            blue ? b - r : r - b,
            greaterThan(25),
            reason: '$painter: $point ($r,$b)',
          );
        }
      } finally {
        image.dispose();
        frame.dispose();
      }
    }
  });

  test('AFF 图形编辑保留分组、注释、换行、扩展指令和标头', () {
    const source =
        '\uFEFFAudioOffset:-42\r\nTimingPointDensityFactor:1.5\r\n'
        '-\r\ntiming(0,120,4);\r\n// {;}\r\n'
        'timinggroup(noinput_anglex120){\r\n'
        '  timing(0,-120,4);(20,1);\r\n'
        '  arc(40,80,0,1,siso,0,1,0,none,true)[arctap(60)];\r\n'
        '  scenecontrol(60,hidegroup,0,1);\r\n};\r\n'
        'camera(0,0,0,0,0,0,0,l,20);\r\n';
    final chart = AffChart.parse(source);
    expect(chart.errors, isEmpty);
    expect(chart.audioOffset, -42);
    expect(chart.unrendered, isEmpty);
    final tap = chart.events.singleWhere((event) => event.kind == AffKind.tap);
    final arc = chart.events.singleWhere((event) => event.kind == AffKind.arc);
    expect(tap.noInput, isTrue);
    expect(arc.arcTaps, [60]);
    expect(
      chart.replace(tap, '(30,2);'),
      source.replaceFirst('(20,1);', '(30,2);'),
    );
    expect(chart.append('(100,4);'), '$source(100,4);\r\n');
    expect(ChartFiles.decode(Uint8List.fromList(utf8.encode(source))), source);
    expect(
      chart.changeAudioOffset(17),
      source.replaceFirst('Offset:-42', 'Offset:17'),
    );
    const commentedOffset = 'AudioOffset:0  // sync\n-\ntiming(0,120,4);\n';
    expect(
      AffChart.parse(commentedOffset).changeAudioOffset(-1),
      commentedOffset.replaceFirst('Offset:0', 'Offset:-1'),
    );
  });

  test('拒绝损坏的时间参数、非整数空键及未结束的分组', () {
    for (final event in [
      'hold(7,3,4);',
      'arc(0,100,0,1,s,0,1,0,none,true)[arctap(1.5)];',
      'timinggroup(noinput){(90,1);',
      'tap(',
    ]) {
      expect(AffChart.parse('${AffChart.blank}$event').errors, isNotEmpty);
    }
  });

  test('原样保留扩展弧线、大 BPM、逆序蛇轨与超出弧线的空键', () {
    const source =
        '${AffChart.blank}timing(1,99999999.00,99999.00);\n'
        'arc(2,8,0,1,s,0,1,1,none,false,3.0);\n'
        'arc(9,8,0,1,s,0,1,0,none,true);\n'
        'arc(10,20,0,1,s,0,1,0,none,true)[arctap(21)];\n';
    final chart = AffChart.parse(source);
    expect(chart.errors, isEmpty);
    expect(chart.unrendered, contains('arc 扩展参数'));
    expect(chart.events[2].smoothness, 3.0);
    expect(ChartTimeline(chart).visible(7, 10), contains(chart.events[3]));
    expect(chart.source, source);
  });

  test('谱面写回保留原件，发现并发变化时拒绝覆盖，并能恢复中断', () async {
    final dir = await Directory.systemTemp.createTemp('chartfiles-');
    addTearDown(() => dir.delete(recursive: true));
    final songs = ArcStorage(dir.path);
    await songs.createDirectory('example');
    final folder = songs.child('example');
    final original = Uint8List.fromList(utf8.encode(AffChart.blank));
    await folder.write('4.aff', original);
    await folder.write('base.ogg', Uint8List(0));
    await folder.write('4.ogg', Uint8List(0));
    final files = ChartFiles(songs, 'example', 4);
    expect((await files.audioSource())!['file'], endsWith('4.ogg'));
    await folder.removeFile('4.ogg');
    expect((await files.audioSource())!['file'], endsWith('base.ogg'));
    final modified = '${AffChart.blank}(125,2);\n';
    expect(await files.open(), original);
    await files.save(original, modified);
    expect(utf8.decode(await files.open()), modified);
    expect(await files.lastBackup(), AffChart.blank);
    final history = await files.backupHistory();
    await history.add(modified);
    final backups = await history.list();
    expect(backups.length, 2);
    expect(await history.read(backups.first), modified);
    expect(await history.read(backups.last), AffChart.blank);
    await history.delete(backups.last);
    expect(await history.list(), [backups.first]);
    expect(utf8.decode(await files.open()), modified);
    await expectLater(
      files.save(original, '${AffChart.blank}(500,1);'),
      throwsStateError,
    );
    await folder.rename('4.aff', '.arcaea-aff-pending-4.aff');
    await folder.write('.arcaea-aff-stage-4.aff', Uint8List(0));
    expect(utf8.decode(await files.open()), modified);
    expect(await folder.kind('.arcaea-aff-stage-4.aff'), isNull);
  });

  testWidgets('在时间轴放置地键、检查源码、撤销并进入试玩', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('地键'));
    await tester.pump();
    final painter = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    final rect = tester.getRect(painter);
    final geometry = TimelineGeometry(rect.size, 0, 2100);
    await tester.tapAt(rect.topLeft + Offset(geometry.x(0.5), rect.height / 2));
    await tester.pump();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    TextField field() =>
        tester.widget(find.byKey(const ValueKey('aff-source')));
    expect(field().controller!.text, isNot(AffChart.blank));
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    expect(field().controller!.text, AffChart.blank);
    await tester.tap(find.text('试玩'));
    await tester.pumpAndSettle();
    expect(find.text('谱面试玩'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  testWidgets('通过镜头面板添加事件并写回可撤销的 AFF 草稿', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('谱面菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('镜头与场景控制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加镜头'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'X 位移'), '1000');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('0 ms · 镜头'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('aff-source')),
    );
    expect(field.controller!.text, contains('camera(0,1000,0,0,0,0,0,l,500);'));
  });

  testWidgets('试玩播放时触碰地键判定区域会记为命中', (tester) async {
    final chart = AffChart.parse('${AffChart.blank}(0,1);\n');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final rect = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartTimelinePainter,
      ),
    );
    final geometry = TimelineGeometry(rect.size, 0, 2100);
    await tester.tapAt(
      rect.topLeft + Offset(geometry.x(0.125), geometry.judgement),
    );
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 1);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  for (final flat in [false, true]) {
    testWidgets('${flat ? '2D' : '3D'} 地键覆盖轨道下方和上方约三个键宽', (tester) async {
      final chart = AffChart.parse('${AffChart.blank}(0,0);(0,2);(0,4);');
      await tester.pumpWidget(
        MaterialApp(
          home: ChartPreviewPage(
            chart: chart,
            timeline: ChartTimeline(chart),
            initial: 0,
            practice: true,
            laneMode: ChartLaneMode.six,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (flat) {
        await tester.tap(find.text('2D'));
        await tester.pumpAndSettle();
      }
      final canvas = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            (flat
                ? widget.painter is ChartTimelinePainter
                : widget.painter is ChartPerspectivePainter),
      );
      await _startPlayback(tester);
      final box = tester.getRect(canvas);
      final plane = TimelineGeometry(box.size, 0, 2100, wideLanes: true);
      final space = PerspectiveGeometry.forPlayback(
        box.size,
        0,
        2100,
        ChartTimeline(chart),
        ChartLaneMode.six,
      );
      ChartHitFrame frame(double lane) => ChartHitFrame.ground(
        lane,
        space: flat ? null : space,
        flat: flat ? plane : null,
        widening: 1,
      )!;
      Offset above(double lane, double fraction) {
        final hit = frame(lane);
        return box.topLeft +
            hit.toScreen(
              hit.center + hit.laneForward * hit.forwardLength * fraction,
            );
      }

      final first = frame(-.125);
      final bottom = (first.back.$1 + first.back.$2) / 2;
      await tester.tapAt(above(.875, 1.20));
      await tester.pump();
      expect(_practiceJudgements(tester).hits, 0);
      await tester.tapAt(
        box.topLeft + first.toScreen(Offset.lerp(first.center, bottom, .98)!),
      );
      await tester.tapAt(above(.375, .82));
      await tester.pump();
      expect(_practiceJudgements(tester).hits, 2);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('蛇跟随时只裁切接住的部分并按 1/32 显示特效，不增加物量', (tester) async {
    final chart = AffChart.parse(
      '${AffChart.blank}arc(0,2000,0.5,0.5,s,0.8,0.8,0,none,false);',
    );
    final timeline = ChartTimeline(chart);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: timeline,
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    await _startPlayback(tester);
    final bounds = tester.getRect(canvas);
    final g = PerspectiveGeometry.forPlayback(
      bounds.size,
      0,
      2100,
      timeline,
      ChartLaneMode.automatic,
    );
    final center = g.projectAir(0.5, 0.8, 0);
    const half = PerspectiveGeometry.arcTapHalfWidth;
    final radius =
        (g.projectArcTap(0.5 - half, 0.8, 0) -
                g.projectArcTap(0.5 + half, 0.8, 0))
            .distance /
        2;
    final playfield =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    final judgement = playfield.judgement!;
    final snake = timeline.notes.single;
    Future<void> playFor(int ms) async {
      elapsed += ms;
      await tester.pump(Duration(milliseconds: ms));
    }

    final touch = await tester.startGesture(
      bounds.topLeft + center.translate(radius * 0.75, 0),
    );
    await playFor(160);
    final held = playfield.position.value;
    expect(judgement.visibleSustain(snake, held - 16, held - 1), isEmpty);
    expect(judgement.hitEffects.map((hit) => hit.at), containsAll([63, 125]));
    expect(_practiceJudgements(tester).hits, 1);
    await touch.up();
    await playFor(50);
    final gap = playfield.position.value;
    expect(judgement.visibleSustain(snake, gap - 16, gap - 1), [
      (start: gap - 16, end: gap - 1),
    ]);
    expect(judgement.hidden(snake, gap), isFalse);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('AFF 自定义持续判定与原指令分离，移动和分段时保留判定点', () {
    const body =
        'hold(100,500,2);\narc(600,1000,0.1,0.8,siso,1,0.6,0,none,false);';
    final chart = AffChart.parse(AffChart.blank + body);
    final notes = chart.events.where((event) => event.isSustain).toList();
    final authored = AffChart.parse(
      chart.withSustainJudgements({
        notes[0]: [170, 170, 490, 510],
        notes[1]: [610, 810],
      }),
    );
    expect(authored.errors, isEmpty);
    expect(authored.source, endsWith(body));
    final edited = authored.events.where((event) => event.isSustain).toList();
    expect(edited[0].sustainJudgements, [170, 490]);
    expect(edited[1].sustainJudgements, [610, 810]);
    final replaced = AffChart.parse(
      authored.replaceEvents({
        edited[0]: 'hold(200,600,2);',
        edited[1]:
            'arc(600,810,0.1,0.5,s,1,0.8,0,none,false);'
            'arc(810,1000,0.5,0.8,s,0.8,0.6,0,none,false);',
      }),
    );
    final changed = replaced.events.where((event) => event.isSustain).toList();
    expect(changed.map((event) => event.sustainJudgements), [
      [270, 590],
      [610, 810],
      <int>[],
    ]);
    final reset = AffChart.parse(
      replaced.withSustainJudgements({changed[0]: null}),
    );
    expect(
      reset.events
          .firstWhere((event) => event.kind == AffKind.hold)
          .sustainJudgements,
      isNull,
    );
  });

  test('新增相同长按保留原配置，直接删改重复指令时提示失配', () {
    const hold = 'hold(100,500,2);';
    final chart = AffChart.parse(AffChart.blank + hold);
    final note = chart.events.singleWhere((event) => event.isSustain);
    final configured = AffChart.parse(
      chart.withSustainJudgements({
        note: [175],
      }),
    );
    final appended = AffChart.parse(configured.appendToGroup(0, hold));
    final holds = appended.events.where((event) => event.isSustain).toList();
    expect(holds.map((event) => event.sustainJudgements), [
      [175],
      null,
    ]);
    expect(appended.warnings, isEmpty);
    final direct = AffChart.parse(
      appended.source.replaceRange(
        holds.first.sourceStart,
        holds.first.sourceEnd,
        '',
      ),
    );
    expect(
      direct.events.singleWhere((event) => event.isSustain).sustainJudgements,
      isNull,
    );
    expect(direct.warnings, hasLength(1));
  });

  testWidgets('编辑后只有手动设置的长按时刻计入物量', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChartEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aff-source')),
      '${AffChart.blank}hold(0,2200,2);',
    );
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(canvas);
    final plane = TimelineGeometry(box.size, 0, 2100);
    await tester.tapAt(box.topLeft + Offset(plane.x(0.375), plane.y(130)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('持续判定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按节拍自动判定'));
    await tester.pumpAndSettle();
    final clear = find.text('清空判定点');
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    final field = find.widgetWithText(TextField, '判定点时间（毫秒）');
    await tester.ensureVisible(field);
    await tester.enterText(field, '72');
    await tester.tap(find.byTooltip('添加判定点'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter;
    expect(painter.timeline.notes.single.sustainJudgements, [72]);
    await tester.tap(find.text('AFF 源码'));
    await tester.pumpAndSettle();
    final written = tester
        .widget<TextField>(find.byKey(const ValueKey('aff-source')))
        .controller!
        .text;
    final chart = AffChart.parse(written);
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: true,
          initial: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    await _startPlayback(tester);
    final practice = tester.getRect(canvas);
    final g = TimelineGeometry(practice.size, 0, 2100);
    final touch = await tester.startGesture(
      practice.topLeft + Offset(g.x(0.375), g.judgement),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 160)),
    );
    await tester.pump(const Duration(milliseconds: 160));
    final played =
        tester.widget<CustomPaint>(canvas).painter! as ChartTimelinePainter;
    expect(_practiceJudgements(tester).hits, 1);
    expect(
      played.judgement!.hitEffects.map((hit) => hit.at),
      containsAll([63, 125]),
    );
    await touch.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('相邻蛇的同一判定点需要两个触点，每指只判一个', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}'
      'arc(-250,1800,0.46,0.46,s,1,1,0,none,false);'
      'arc(-250,1800,0.70,0.70,s,1,1,1,none,false);',
    );
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        for (final note in raw.events.where((note) => note.isSustain))
          note: [100],
      }),
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final bounds = tester.getRect(canvas);
    final plane = TimelineGeometry(bounds.size, 0, 2100);
    Offset at(double x) =>
        bounds.topLeft + Offset(plane.x(x, airborne: true), plane.judgement);
    final first = await tester.startGesture(at(0.55), pointer: 15);
    await tester.pump();
    elapsed = 100;
    await tester.pump(const Duration(milliseconds: 16));
    expect(_practiceJudgements(tester).hits, 1);
    elapsed = 118;
    final second = await tester.startGesture(at(0.34), pointer: 16);
    await tester.pump();
    expect(_practiceJudgements(tester).hits, 2);
    final report =
        tester.widget<CustomPaint>(canvas).foregroundPainter!
            as PracticeFeedbackPainter;
    expect(
      report.judgements.history.map((entry) => entry.offset),
      unorderedEquals([0.0, -18.0]),
    );
    await second.up();
    await first.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('持续判定点晚接 24 ms 可得大 P，晚接 26 ms 记 LOST', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}hold(0,1000,2);'
      'arc(0,1000,0.7,0.7,s,1,1,1,none,false);',
    );
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        for (final note in raw.events.where((note) => note.isSustain))
          note: [100, 300],
      }),
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final box = tester.getRect(canvas);
    final g = TimelineGeometry(box.size, 0, 2100);
    final hold = box.topLeft + Offset(g.x(.375), g.judgement);
    final snake = box.topLeft + Offset(g.x(.70, airborne: true), g.judgement);
    elapsed = 124;
    final a = await tester.startGesture(hold, pointer: 21);
    final b = await tester.startGesture(snake, pointer: 22);
    await tester.pump(const Duration(milliseconds: 16));
    elapsed = 140;
    await a.up();
    await b.up();
    elapsed = 326;
    final c = await tester.startGesture(hold, pointer: 23);
    final d = await tester.startGesture(snake, pointer: 24);
    await tester.pump(const Duration(milliseconds: 16));
    elapsed = 480;
    await tester.pump(const Duration(milliseconds: 16));
    final history =
        (tester.widget<CustomPaint>(canvas).foregroundPainter!
                as PracticeFeedbackPainter)
            .judgements
            .history;
    expect(history.map((hit) => hit.grade), [
      PracticeGrade.shiny,
      PracticeGrade.shiny,
      PracticeGrade.lost,
      PracticeGrade.lost,
    ]);
    expect(history.map((hit) => hit.offset), [-24.0, -24.0, null, null]);
    await c.up();
    await d.up();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('同一触点提前命中天键后也可判蛇，提前松手仍计分', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}'
      'arc(0,1000,0.5,0.5,s,1,1,1,none,false);'
      'arc(100,100,0.5,0.5,s,1,1,0,none,true)[arctap(100)];',
    );
    final snake = raw.events.singleWhere((event) => event.isSustain);
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        snake: [100],
      }),
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartTimelinePainter,
    );
    await _startPlayback(tester);
    final box = tester.getRect(canvas);
    final g = TimelineGeometry(box.size, 0, 2100);
    elapsed = 75;
    final finger = await tester.startGesture(
      box.topLeft + Offset(g.x(.5, airborne: true), g.judgement),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await finger.up();
    elapsed = 280;
    await tester.pump(const Duration(milliseconds: 16));
    final report =
        tester.widget<CustomPaint>(canvas).foregroundPainter!
            as PracticeFeedbackPainter;
    expect(report.judgements.history.map((hit) => (hit.key, hit.grade)), [
      (PracticeKey.air, PracticeGrade.shiny),
      (PracticeKey.snake, PracticeGrade.shiny),
    ]);
    expect(report.judgements.history.last.offset, 25);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('长按提前 25 ms 可判，独占点键，蛇可复用长按触点', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}(100,2);hold(20,750,2);'
      'arc(20,750,.375,.375,s,1,1,1,none,false);',
    );
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        for (final event in raw.events.where((event) => event.isSustain))
          event: [100, 300, 500],
      }),
    );
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await tester.tap(find.text('叠加地键和空键'));
    await tester.pump();
    await _startPlayback(tester);
    final canvas = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(canvas);
    final g = TimelineGeometry(box.size, 0, 2100, overlay: true);
    final hit = box.topLeft + Offset(g.x(.375), g.judgement);
    final report = _practiceJudgements(tester);
    for (final time in [75.0, 275.0, 474.0]) {
      elapsed = time;
      await tester.tapAt(hit);
      await tester.pump(const Duration(milliseconds: 16));
    }
    elapsed = 700;
    await tester.pump(const Duration(milliseconds: 16));
    for (final (key, offsets, lost) in [
      (PracticeKey.ground, [25.0], 0),
      (PracticeKey.hold, [25.0], 2),
      (PracticeKey.snake, [25.0, 25.0], 1),
    ]) {
      final results = report.history.where((hit) => hit.key == key);
      expect(
        results
            .where((hit) => hit.grade == PracticeGrade.shiny)
            .map((hit) => hit.offset),
        offsets,
      );
      expect(
        results.where((hit) => hit.grade == PracticeGrade.lost).length,
        lost,
      );
    }
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('重叠的两个长按判定窗只接受一次瞬时点击', (tester) async {
    final raw = AffChart.parse(
      '${AffChart.blank}hold(20,400,2);hold(50,450,2);',
    );
    final holds = raw.events.where((note) => note.isSustain).toList();
    final chart = AffChart.parse(
      raw.withSustainJudgements({
        holds[0]: [100],
        holds[1]: [115],
      }),
    );
    var time = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          initial: 0,
          practice: true,
          debugElapsedMilliseconds: () => time,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2D'));
    await tester.pump();
    await _startPlayback(tester);
    final finder = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
    );
    final box = tester.getRect(finder);
    final g = TimelineGeometry(box.size, 0, 2100);
    time = 115;
    await tester.tapAt(box.topLeft + Offset(g.x(.375), g.judgement));
    await tester.pump();
    time = 400;
    await tester.pump(const Duration(milliseconds: 16));
    final report = _practiceJudgements(tester);
    expect(report.history.map((hit) => hit.grade), [
      PracticeGrade.shiny,
      PracticeGrade.lost,
    ]);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  test('2D 同时刻对齐，3D 同时刻保留高度且远处收窄', () {
    const size = Size(400, 600);
    const flat = TimelineGeometry(size, 750, 2100);
    expect(flat.x(0.5), lessThan(flat.centerGap));
    expect(flat.x(0.5, airborne: true), greaterThan(flat.centerGap));
    expect(flat.y(750), flat.judgement);
    expect(flat.time(flat.y(500)), closeTo(500, 1e-6));
    for (final coordinate in [-0.25, 1.25]) {
      final x = flat.x(coordinate, airborne: true);
      expect(x, inInclusiveRange(flat.centerGap, size.width));
      expect(flat.trackX(x, airborne: true), closeTo(coordinate, 1e-6));
    }
    final depth = PerspectiveGeometry(size, 750, 2100);
    expect(
      depth.projectAir(0.5, 0, 750).dy,
      lessThan(depth.project(0.5, 0, 750).dy),
    );
    expect(
      depth.projectAir(0.5, 1, 750).dy,
      lessThan(depth.projectAir(0.5, 0, 750).dy),
    );
    expect(depth.project(1, 0, 2500).dx, lessThan(depth.project(1, 0, 750).dx));
  });

  for (final practice in [false, true]) {
    testWidgets('${practice ? '试玩' : '预览'}启动时音频读数波动不会让谱面前后跳动', (tester) async {
      if (!Platform.isWindows && !Platform.isAndroid) return;
      const channel = MethodChannel('arcaea_manager/chart_audio');
      final binding =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final samples = <List<Object>>[
        [1050, false],
        [1250, true],
        [1500, true],
        [1680, true],
      ];
      var reads = 0;
      var elapsed = 0.0;
      double? delayedAt;
      final delayedSample = Completer<List<Object>>();
      binding.setMockMethodCallHandler(channel, (method) async {
        if (method.method == 'position') {
          final index = (reads++).clamp(0, samples.length - 1);
          if (index == 1) {
            delayedAt = elapsed;
            return delayedSample.future;
          }
          return samples[index];
        }
        return switch (method.method) {
          'open' => 5000,
          'seek' => (method.arguments as Map)['position'],
          _ => null,
        };
      });
      addTearDown(() => binding.setMockMethodCallHandler(channel, null));
      final chart = AffChart.parse('AudioOffset:50\n-\ntiming(0,120,4);\n');
      await tester.pumpWidget(
        MaterialApp(
          home: ChartPreviewPage(
            chart: chart,
            timeline: ChartTimeline(chart),
            practice: practice,
            initial: 1000,
            audio: () async => {'file': 'music.ogg'},
            debugElapsedMilliseconds: () => elapsed,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final canvas = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ChartPerspectivePainter,
      );
      final painter =
          tester.widget<CustomPaint>(canvas).painter!
              as ChartPerspectivePainter;
      await _startPlayback(tester);
      var previous = painter.position.value;
      var corrected = false;
      expect(previous, 1000);
      for (var frame = 0; frame < 50; frame++) {
        elapsed += 16;
        final at = delayedAt;
        if (at != null && elapsed - at >= 96 && !delayedSample.isCompleted) {
          delayedSample.complete(samples[1]);
        }
        await tester.pump(const Duration(milliseconds: 16));
        final current = painter.position.value;
        expect(current - previous, inInclusiveRange(13, 19));
        if (reads < 3) expect(current - previous, 16);
        corrected |= (current - previous - 16).abs() > .1;
        previous = current;
      }
      expect(reads, greaterThanOrEqualTo(4));
      expect(corrected, isTrue);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('暂停前未返回的音频读数不会影响续播', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    const channel = MethodChannel('arcaea_manager/chart_audio');
    final binding =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final oldSample = Completer<List<Object>>();
    var seeks = 0, reads = 0;
    binding.setMockMethodCallHandler(channel, (method) async {
      switch (method.method) {
        case 'open':
          return 5000;
        case 'seek':
          seeks++;
          return (method.arguments as Map)['position'];
        case 'position':
          reads++;
          return oldSample.future;
      }
      return null;
    });
    addTearDown(() => binding.setMockMethodCallHandler(channel, null));
    final chart = AffChart.parse(AffChart.blank);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: false,
          initial: 1000,
          audio: () async => {'file': 'music.ogg'},
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    await _startPlayback(tester);
    elapsed = 176;
    await tester.pump(const Duration(milliseconds: 176));
    expect(reads, 1);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    final pausedAt = painter.position.value;
    expect(pausedAt, 1176);
    elapsed = 0;
    await _startPlayback(tester);
    expect(seeks, 2);
    oldSample.complete([250, true]);
    await tester.pump();
    elapsed = 16;
    await tester.pump(const Duration(milliseconds: 16));
    expect(painter.position.value, pausedAt + 16);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('按音频实际定位开播，谱面先到尾点时等待音频播完', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    const channel = MethodChannel('arcaea_manager/chart_audio');
    final binding =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var reads = 0, pauses = 0;
    binding.setMockMethodCallHandler(channel, (method) async {
      switch (method.method) {
        case 'open':
          return 1500;
        case 'seek':
          return 800;
        case 'position':
          return reads++ == 0 ? [1440, true] : [1500, false];
        case 'pause':
          pauses++;
      }
      return null;
    });
    addTearDown(() => binding.setMockMethodCallHandler(channel, null));
    final chart = AffChart.parse(AffChart.blank);
    var elapsed = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: false,
          initial: 1000,
          audio: () async => {'file': 'music.ogg'},
          debugElapsedMilliseconds: () => elapsed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is ChartPerspectivePainter,
    );
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as ChartPerspectivePainter;
    await _startPlayback(tester);
    expect(painter.position.value, 800);
    elapsed = 700;
    await tester.pump(const Duration(milliseconds: 700));
    expect(painter.position.value, 1500);
    expect(reads, 1);
    expect(pauses, 0);
    elapsed = 880;
    await tester.pump(const Duration(milliseconds: 180));
    elapsed = 896;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(pauses, 1);
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  testWidgets('切换 2D/3D 保留音频会话，播放定位考虑 AFF 偏移和校准', (tester) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    SharedPreferences.setMockInitialValues({
      'chart_preview_delay_ms': 25,
      'chart_preview_scroll_speed': 2.0,
    });
    const channel = MethodChannel('arcaea_manager/chart_audio');
    final invocations = <MethodCall>[];
    final binding =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binding.setMockMethodCallHandler(channel, (method) async {
      invocations.add(method);
      return switch (method.method) {
        'open' => 10000,
        'seek' => (method.arguments as Map)['position'],
        'position' => [225, true],
        _ => null,
      };
    });
    addTearDown(() => binding.setMockMethodCallHandler(channel, null));
    final chart = AffChart.parse('AudioOffset:40\n-\ntiming(0,120,4);\n');
    await tester.pumpWidget(
      MaterialApp(
        home: ChartPreviewPage(
          chart: chart,
          timeline: ChartTimeline(chart),
          practice: false,
          initial: 160,
          audio: () async => {'file': 'music.ogg'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter is ChartPerspectivePainter &&
            (w.painter! as ChartPerspectivePainter).lookahead == 1050,
      ),
      findsOneWidget,
    );
    await _startPlayback(tester);
    await tester.tap(find.text('2D'));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ChartTimelinePainter,
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(
      invocations.where((method) => method.method == 'open'),
      hasLength(1),
    );
    expect(
      invocations.singleWhere((method) => method.method == 'seek').arguments,
      {'position': 225},
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(invocations.last.method, 'close');
  });
}
