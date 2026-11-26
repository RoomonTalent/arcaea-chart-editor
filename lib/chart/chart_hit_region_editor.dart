import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_feedback.dart';
import 'chart_hit_regions.dart';
import 'chart_millisecond_input.dart';
import 'chart_perspective.dart';
import 'chart_playback_view.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';

class ChartHitRegionEditor extends StatefulWidget {
  const ChartHitRegionEditor({
    super.key,
    required this.initial,
    required this.timing,
    required this.playbackView,
    required this.perspective,
    required this.lanes,
    required this.overlay,
    required this.appearance,
    this.skin,
    this.showTiming = false,
  });

  final Map<bool, Map<ChartHitKind, ChartHitArea>> initial;
  final Map<bool, Map<PracticeKey, PracticeWindows>> timing;
  final ChartPlaybackView playbackView;
  final ChartLaneMode lanes;
  final bool perspective, overlay;
  final ChartAppearance appearance;
  final ValueListenable<ChartSkin>? skin;
  final bool showTiming;

  @override
  State<ChartHitRegionEditor> createState() => _ChartHitRegionEditorState();
}

typedef ChartHitEditorResult = ({
  Map<bool, Map<ChartHitKind, ChartHitArea>> areas,
  Map<bool, Map<PracticeKey, PracticeWindows>> timing,
});

typedef _BoundaryDrag = ({
  int pointer,
  ChartHitKind kind,
  ChartHitFrame frame,
  ChartHitArea area,
  Offset start,
  int index,
  bool edge,
});

const _regionColors = {
  ChartHitKind.tap: Color(0xFF6EE7BD),
  ChartHitKind.hold: Color(0xFFFFD985),
  ChartHitKind.arc: Color(0xFFFF8DA5),
  ChartHitKind.sky: Color(0xFFC8ABFF),
};

class _ChartHitRegionEditorState extends State<ChartHitRegionEditor> {
  static final _demo = ChartTimeline(
    AffChart.parse(
      '${AffChart.blank}(0,1);hold(0,500,4);'
      'arc(-180,540,0.18,0.18,s,0.55,0.55,1,none,false);'
      'arc(0,0,0.82,0.82,s,1,1,0,none,true)[arctap(0)];',
    ),
  );
  final _cursor = ValueNotifier(0.0);
  late final _profiles = {
    for (final mode in [false, true]) mode: {...?widget.initial[mode]},
  };
  late final _timeProfiles = {
    for (final mode in [false, true]) mode: {...?widget.timing[mode]},
  };
  Map<ChartHitKind, ChartHitArea> get _areas => _profiles[_perspective]!;
  Map<PracticeKey, PracticeWindows> get _timing => _timeProfiles[_perspective]!;
  late bool _perspective = widget.perspective;
  ChartHitKind _selected = ChartHitKind.tap;
  int _vertex = 0;
  late bool _showSettings = widget.showTiming;
  late bool _timeSettings = widget.showTiming;
  bool _editLateWindow = false;
  final _unchangedDefaults = <(bool, PracticeKey)>{};
  PracticeKey _timingKey = PracticeKey.ground;
  _BoundaryDrag? _drag;

  ChartHitArea _area(ChartHitKind kind) =>
      _areas[kind] ?? ChartHitArea.defaults(kind);

  Map<ChartHitKind, ChartHitFrame> _frames(Size size) {
    final space = _perspective
        ? PerspectiveGeometry.forPlayback(
            size,
            0,
            2100,
            _demo,
            widget.lanes,
            view: widget.playbackView,
          )
        : null;
    final flat = _perspective
        ? null
        : TimelineGeometry(
            size,
            0,
            2100,
            wideLanes: widget.lanes == ChartLaneMode.six,
            overlay: widget.overlay,
          );
    final widening = widget.lanes == ChartLaneMode.six ? 1.0 : 0.0;
    return {
      ChartHitKind.tap: ChartHitFrame.ground(
        .125,
        space: space,
        flat: flat,
        widening: widening,
      )!,
      ChartHitKind.hold: ChartHitFrame.ground(
        .875,
        space: space,
        flat: flat,
        widening: widening,
      )!,
      ChartHitKind.arc: ChartHitFrame.air(
        (x: .18, height: .55),
        skyTap: false,
        space: space,
        flat: flat,
      )!,
      ChartHitKind.sky: ChartHitFrame.air(
        (x: .82, height: 1.0),
        skyTap: true,
        space: space,
        flat: flat,
      )!,
    };
  }

  void _begin(PointerDownEvent event, Map<ChartHitKind, ChartHitFrame> frames) {
    if (_drag != null ||
        (event.kind == PointerDeviceKind.mouse &&
            (event.buttons & kPrimaryButton) == 0)) {
      return;
    }
    final point = event.localPosition;
    _BoundaryDrag? nearest;
    ChartHitKind? inside;
    var best = event.kind == PointerDeviceKind.touch ? 20.0 : 13.0;
    var bestCenter = double.infinity;
    for (final kind in [
      _selected,
      ...ChartHitKind.values.where((kind) => kind != _selected),
    ]) {
      final frame = frames[kind]!;
      final area = _area(kind);
      void consider(double distance, int index, {required bool edge}) {
        if (distance >= best) return;
        best = distance;
        nearest = (
          pointer: event.pointer,
          kind: kind,
          frame: frame,
          area: area,
          start: point,
          index: index,
          edge: edge,
        );
      }

      if (kind == _selected) {
        for (final (index, handle) in frame.handles(area).indexed) {
          // Prefer a visible handle over its adjoining edges.
          consider((point - handle).distance * .55, index, edge: false);
        }
      }
      final line = frame.outline(area);
      for (var i = 0; i < line.length; i++) {
        final next = (i + 1) % line.length;
        final index = area.shape == ChartHitShape.oval
            ? ((i + 8) ~/ 16) % 4
            : i;
        consider(
          _segmentDistance(point, line[i], line[next]),
          index,
          edge: true,
        );
      }
      final centerDistance = (point - frame.toScreen(frame.center)).distance;
      if (centerDistance < bestCenter && frame.distance(area, point) != null) {
        inside = kind;
        bestCenter = centerDistance;
      }
    }
    final kind = nearest?.kind ?? inside;
    if (kind == null) return;
    setState(() {
      _selected = kind;
      _drag = nearest;
      if (nearest?.area.shape == ChartHitShape.quadrilateral) {
        _vertex = nearest!.index;
      }
    });
  }

  void _move(PointerMoveEvent event) {
    final drag = _drag;
    if (drag == null || drag.pointer != event.pointer) return;
    final frame = drag.frame, area = drag.area;
    final delta =
        frame.fromScreen(event.localPosition) - frame.fromScreen(drag.start);
    final index = drag.index;
    double scale(double value) => value.clamp(.05, 8.0);
    final top = drag.edge ? index == 0 : index < 2;
    final bottom = drag.edge ? index == 2 : index >= 2;
    final left = drag.edge ? index == 3 : index == 0 || index == 3;
    final right = drag.edge ? index == 1 : index == 1 || index == 2;
    final ChartHitArea updated;
    switch (area.shape) {
      case ChartHitShape.quadrilateral:
        final vertices = [...area.vertices];
        void move(int i) {
          final point = vertices[i] + delta / frame.radius;
          vertices[i] = Offset(
            point.dx.clamp(-8.0, 8.0),
            point.dy.clamp(-8.0, 8.0),
          );
        }
        move(index);
        if (drag.edge) move((index + 1) % 4);
        updated = area.copyWith(vertices: vertices);
      case ChartHitShape.oval:
        final x = index.isEven ? (index == 0 ? delta.dx : -delta.dx) : 0.0;
        final y = index.isOdd ? (index == 1 ? delta.dy : -delta.dy) : 0.0;
        updated = area.copyWith(
          width: scale(area.width + x / frame.radius),
          height: scale(area.height + y / (frame.radius * 1.10)),
        );
      case ChartHitShape.square:
      case ChartHitShape.rectangle:
        final x =
            (left
                ? -delta.dx
                : right
                ? delta.dx
                : 0) /
            frame.radius;
        final y =
            (top
                ? -delta.dy
                : bottom
                ? delta.dy
                : 0) /
            frame.radius;
        updated = area.shape == ChartHitShape.square
            ? area.copyWith(
                width: scale(area.width + (x.abs() >= y.abs() ? x : y)),
              )
            : area.copyWith(
                width: scale(area.width + x),
                height: scale(area.height + y),
              );
      case ChartHitShape.lane:
        double component(Offset axis) =>
            delta.dx * axis.dx + delta.dy * axis.dy;
        final x =
            component(frame.laneAcross) *
            (left
                ? -1
                : right
                ? 1
                : 0);
        final along = component(frame.laneForward);
        updated = area.copyWith(
          width: scale(area.width + x / frame.laneHalfWidth),
          forward: scale(
            area.forward + (top ? along / frame.forwardLength : 0),
          ),
          backward: scale(
            area.backward - (bottom ? along / frame.backwardLength : 0),
          ),
        );
    }
    setState(() => _areas[drag.kind] = updated);
  }

  void _finish(PointerEvent event) {
    if (_drag?.pointer == event.pointer) _drag = null;
  }

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty) return const SizedBox.shrink();
        final frames = _frames(size);
        final areas = {
          for (final kind in ChartHitKind.values) kind: _area(kind),
        };
        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _begin(event, frames),
              onPointerMove: _move,
              onPointerUp: _finish,
              onPointerCancel: _finish,
              child: ValueListenableBuilder(
                valueListenable:
                    widget.skin ??
                    const AlwaysStoppedAnimation(ChartSkin.defaults),
                builder: (context, skin, _) => CustomPaint(
                  painter: _perspective
                      ? ChartPerspectivePainter(
                          _demo,
                          _cursor,
                          2100,
                          skin: skin,
                          playbackFraming: true,
                          laneMode: widget.lanes,
                          playbackView: widget.playbackView,
                          appearance: widget.appearance,
                        )
                      : ChartTimelinePainter(
                          _demo,
                          _cursor,
                          2100,
                          skin: skin,
                          preview: true,
                          laneMode: widget.lanes,
                          overlay: widget.overlay,
                          appearance: widget.appearance,
                        ),
                  foregroundPainter: _HitAreasPainter(frames, areas, _selected),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                minimum: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    borderRadius: BorderRadius.circular(12),
                    color: Theme.of(context).colorScheme.surface,
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const BackButton(),
                        const Text('判定范围'),
                        TextButton(
                          onPressed: () => setState(() {
                            _drag = null;
                            _perspective = !_perspective;
                          }),
                          child: Text(_perspective ? '3D' : '2D'),
                        ),
                        IconButton(
                          tooltip: _showSettings ? '收起判定参数' : '展开判定参数',
                          icon: const Icon(Icons.tune),
                          onPressed: () =>
                              setState(() => _showSettings = !_showSettings),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, (
                            areas: _profiles,
                            timing: _timeProfiles,
                          )),
                          child: const Text('应用'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_showSettings)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 62,
                right: 8,
                bottom: MediaQuery.paddingOf(context).bottom + 8,
                width: math.min(312, size.width - 16),
                child: Align(
                  alignment: Alignment.topRight,
                  child: _parameters(),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _parameters() {
    final area = _area(_selected);
    void change(ChartHitArea next) => setState(() => _areas[_selected] = next);
    return Card(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('空间范围')),
                ButtonSegment(value: true, label: Text('时间判定')),
              ],
              selected: {_timeSettings},
              onSelectionChanged: (value) =>
                  setState(() => _timeSettings = value.single),
            ),
            if (_timeSettings)
              ..._timingControls()
            else ...[
              Wrap(
                spacing: 5,
                children: [
                  for (final kind in ChartHitKind.values)
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: kind == _selected,
                      avatar: CircleAvatar(
                        backgroundColor: _regionColors[kind],
                      ),
                      onSelected: (_) => setState(() {
                        _selected = kind;
                        _vertex = 0;
                      }),
                    ),
                ],
              ),
              DropdownButton<ChartHitShape>(
                key: const ValueKey('hit-area-shape'),
                isExpanded: true,
                value: area.shape,
                items: [
                  for (final shape in ChartHitShape.values)
                    DropdownMenuItem(value: shape, child: Text(shape.label)),
                ],
                onChanged: (shape) {
                  if (shape != null) change(area.copyWith(shape: shape));
                },
              ),
              if (area.shape == ChartHitShape.quadrilateral) ...[
                const Text('顶点坐标以按键中心为原点，Y 向下为正。'),
                Wrap(
                  spacing: 5,
                  children: [
                    for (var i = 0; i < 4; i++)
                      ChoiceChip(
                        label: Text('${i + 1}'),
                        selected: i == _vertex,
                        onSelected: (_) => setState(() => _vertex = i),
                      ),
                  ],
                ),
                _slider('顶点横坐标', area.vertices[_vertex].dx, (value) {
                  final points = [...area.vertices];
                  points[_vertex] = Offset(value, points[_vertex].dy);
                  change(area.copyWith(vertices: points));
                }, min: -8),
                _slider('顶点纵坐标', area.vertices[_vertex].dy, (value) {
                  final points = [...area.vertices];
                  points[_vertex] = Offset(points[_vertex].dx, value);
                  change(area.copyWith(vertices: points));
                }, min: -8),
              ] else ...[
                _slider(
                  area.shape == ChartHitShape.square
                      ? '边长'
                      : area.shape == ChartHitShape.lane
                      ? '垂直轨道方向'
                      : '宽度',
                  area.width,
                  (value) => change(area.copyWith(width: value)),
                ),
                if (area.shape == ChartHitShape.lane) ...[
                  _slider(
                    '沿轨道向上',
                    area.forward,
                    (value) => change(area.copyWith(forward: value)),
                  ),
                  _slider(
                    '沿轨道向下',
                    area.backward,
                    (value) => change(area.copyWith(backward: value)),
                  ),
                ] else if (area.shape != ChartHitShape.square)
                  _slider(
                    '高度',
                    area.height,
                    (value) => change(area.copyWith(height: value)),
                  ),
              ],
              TextButton(
                onPressed: () => change(ChartHitArea.defaults(_selected)),
                child: const Text('恢复当前键型默认值'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _timingControls() {
    final key = _timingKey;
    final profile = (_perspective, key);
    final windows = _timing[key] ?? defaultPracticeWindows(key);
    final independent = windows.late != null;
    final late = independent && _editLateWindow;
    final side = late ? windows.after : windows.early;
    final automaticSample = key.isSustain && !_timing.containsKey(key)
        ? (early: 125.0, late: automaticSustainLateWindow)
        : null;
    void edit(PracticeWindows value) => setState(() {
      _unchangedDefaults.remove(profile);
      _timing[key] = value;
    });
    void editSide(PracticeWindowSide value) => edit(
      late
          ? (early: windows.early, late: value)
          : (early: value, late: windows.late),
    );
    Widget limit(
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> change,
    ) => _msSlider(
      label,
      value,
      min,
      max,
      change,
      independent: independent,
      late: late,
    );
    return [
      DropdownButton<PracticeKey>(
        isExpanded: true,
        value: key,
        items: [
          for (final item in PracticeKey.values)
            DropdownMenuItem(value: item, child: Text(item.label)),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _timingKey = value);
        },
      ),
      Text(
        key.isSustain
            ? '自动判定点的提前范围为切分间隔的一半，且从键头开始。晚接允许 500 ms。图示为 120 BPM、密度 1 的常规判定点。AFF 手动判定点默认 ±25 ms。自定义时间窗会覆盖此键型的默认值。'
            : '默认大 PURE 0–25 ms，小 PURE 25–50 ms，FAR 50–100 ms，100–120 ms 的点击计 LOST。早晚对称。',
      ),
      SwitchListTile(
        title: const Text('提前与延后独立设置'),
        value: independent,
        contentPadding: EdgeInsets.zero,
        onChanged: (enabled) => setState(() {
          _editLateWindow = false;
          if (enabled) {
            if (!_timing.containsKey(key)) _unchangedDefaults.add(profile);
            _timing[key] = automaticSample == null
                ? (early: windows.early, late: windows.early)
                : (
                    early: sustainWindowSide(automaticSample.early),
                    late: sustainWindowSide(automaticSample.late),
                  );
          } else if (_unchangedDefaults.remove(profile)) {
            _timing.remove(key);
          } else {
            _timing[key] = (early: windows.early, late: null);
          }
        }),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 12,
        child: CustomPaint(painter: _TimingSample(windows, automaticSample)),
      ),
      const SizedBox(height: 8),
      if (independent) ...[
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('提前（−）')),
            ButtonSegment(value: true, label: Text('延后（+）')),
          ],
          selected: {late},
          onSelectionChanged: (value) =>
              setState(() => _editLateWindow = value.single),
        ),
        const SizedBox(height: 8),
      ],
      if (key.isSustain)
        limit(
          '大 PURE',
          side.shiny,
          0,
          1000,
          (value) => editSide(sustainWindowSide(value)),
        )
      else ...[
        limit(
          '大 PURE',
          side.shiny,
          0,
          side.pure,
          (value) => editSide((
            shiny: value,
            pure: side.pure,
            far: side.far,
            capture: side.capture,
          )),
        ),
        limit(
          '小 PURE',
          side.pure,
          side.shiny,
          side.far,
          (value) => editSide((
            shiny: side.shiny,
            pure: value,
            far: side.far,
            capture: side.capture,
          )),
        ),
        limit(
          'FAR',
          side.far,
          side.pure,
          side.capture,
          (value) => editSide((
            shiny: side.shiny,
            pure: side.pure,
            far: value,
            capture: side.capture,
          )),
        ),
        limit(
          'LOST 点击上限',
          side.capture,
          side.far,
          1000,
          (value) => editSide((
            shiny: side.shiny,
            pure: side.pure,
            far: side.far,
            capture: value,
          )),
        ),
      ],
      TextButton(
        onPressed: () => setState(() {
          _timing.remove(key);
          _unchangedDefaults.remove(profile);
        }),
        child: const Text('恢复默认时间窗'),
      ),
    ];
  }

  Widget _msSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> update, {
    required bool independent,
    required bool late,
  }) {
    final early = independent && !late;
    final inputMin = early ? -max.floor() : min.ceil();
    final inputMax = early ? -min.ceil() : max.floor();
    final sign = !independent
        ? '±'
        : late
        ? '+'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChartMillisecondInput(
          key: ValueKey((_perspective, _timingKey, independent, late, label)),
          label: '$label（$sign$inputMin～$sign$inputMax）',
          value: early ? -value.round() : value.round(),
          min: inputMin,
          max: inputMax,
          onChanged: (value) => update((early ? -value : value).toDouble()),
        ),
        Slider(
          min: min,
          max: max,
          divisions: min < max ? math.max(1, (max - min).round()) : null,
          value: value.clamp(min, max),
          onChanged: min == max
              ? null
              : (next) => update(next.roundToDouble().clamp(min, max)),
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> update, {
    double min = .05,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label  ${value.toStringAsFixed(2)}'),
      Slider(min: min, max: 8, value: value.clamp(min, 8.0), onChanged: update),
    ],
  );
}

class _TimingSample extends CustomPainter {
  const _TimingSample(this.windows, this.sustainWindow);
  final PracticeWindows windows;
  final PracticeSustainWindow? sustainWindow;

  @override
  void paint(Canvas canvas, Size size) => paintPracticeTimingBar(
    canvas,
    Offset.zero & size,
    windows,
    sustainWindow: sustainWindow,
  );

  @override
  bool shouldRepaint(_TimingSample oldDelegate) =>
      oldDelegate.windows != windows ||
      oldDelegate.sustainWindow != sustainWindow;
}

double _segmentDistance(Offset p, Offset a, Offset b) {
  final axis = b - a, from = p - a;
  if (axis.distanceSquared < 1e-8) return from.distance;
  final fraction =
      ((from.dx * axis.dx + from.dy * axis.dy) / axis.distanceSquared).clamp(
        0.0,
        1.0,
      );
  return (from - axis * fraction).distance;
}

class _HitAreasPainter extends CustomPainter {
  const _HitAreasPainter(this.frames, this.areas, this.selected);

  final Map<ChartHitKind, ChartHitFrame> frames;
  final Map<ChartHitKind, ChartHitArea> areas;
  final ChartHitKind selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final kind in [
      ...ChartHitKind.values.where((kind) => kind != selected),
      selected,
    ]) {
      final frame = frames[kind]!, area = areas[kind]!;
      final color = _regionColors[kind]!;
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addPolygon(frame.outline(area), true);
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: kind == selected ? .13 : .05),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = kind == selected ? 2.5 : 1.4,
      );
      final center = frame.toScreen(frame.center);
      canvas.drawCircle(center, 3, Paint()..color = color);
      if (kind == selected) {
        for (final p in frame.handles(area)) {
          canvas.drawCircle(p, 6, Paint()..color = const Color(0xFF20192B));
          canvas.drawCircle(p, 4, Paint()..color = color);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HitAreasPainter oldDelegate) => true;
}
