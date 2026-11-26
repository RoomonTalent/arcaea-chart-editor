import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_editor_visibility.dart';
import 'chart_practice_segment.dart';
import 'chart_scene.dart';
import 'chart_scroll.dart';
import 'chart_skin.dart';

enum ChartLaneMode {
  automatic('自动'),
  four('4K'),
  six('6K');

  const ChartLaneMode(this.label);
  final String label;

  double expansion(
    ChartTimeline timeline,
    double time, {
    bool editing = false,
  }) => switch (this) {
    four => 0,
    six => 1,
    automatic when !timeline.scene.hasLaneEvents => timeline.wideLanes ? 1 : 0,
    automatic => timeline.scene.lanes(time),
  };

  bool shows(AffEvent note) =>
      this != four ||
      note.isAir ||
      note.groundPosition != null ||
      (note.laneX >= 0 && note.laneX <= 1);

  bool showsAt(ChartTimeline timeline, AffEvent note, double time) =>
      note.isAir ||
      note.groundPosition != null ||
      (note.laneX >= 0 && note.laneX <= 1) ||
      expansion(timeline, time) > 0;
}

class ChartLaneMenu extends StatelessWidget {
  const ChartLaneMenu({super.key, required this.mode, required this.onChanged});

  final ChartLaneMode mode;
  final ValueChanged<ChartLaneMode>? onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ChartLaneMode>(
    tooltip: '轨道模式',
    enabled: onChanged != null,
    initialValue: mode,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final option in ChartLaneMode.values)
        CheckedPopupMenuItem(
          value: option,
          checked: mode == option,
          child: Text(option.label),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Text(mode.label),
    ),
  );
}

typedef ChartHit = ({
  double at,
  double x,
  double height,
  bool air,
  bool arcTap,
  int group,
  int count,
  int? targetTime,
});
typedef ChartTimeSpan = ({double start, double end});
const automaticSustainLateWindow = 500.0;

/// Chart-time feedback remains in sync when pausing, resuming or seeking.
class ChartJudgement {
  static const duration = 210.0;
  final hitEffects = <ChartHit>[];
  final earlyHolds = <AffEvent>{};
  final _hidden = <({AffEvent note, int? tap}), double>{};
  final _hitTaps = <({AffEvent note, int tap}), int>{};
  final _held = <AffEvent, List<ChartTimeSpan>>{};

  void hide(AffEvent note, double at, {int? tap, bool immediately = false}) {
    _hidden[(note: note, tap: tap)] = immediately
        ? double.negativeInfinity
        : at + duration;
  }

  bool hidden(AffEvent note, double time, {int? tap}) =>
      time >= (_hidden[(note: note, tap: tap)] ?? double.infinity);

  int remainingTaps(AffEvent note, int tap, double time) {
    if (hidden(note, time, tap: tap)) return 0;
    return note.arcTapCounts[tap]! - (_hitTaps[(note: note, tap: tap)] ?? 0);
  }

  void hitTap(AffEvent note, int tap, double time) {
    final key = (note: note, tap: tap);
    final count = (_hitTaps[key] ?? 0) + 1;
    _hitTaps[key] = count;
    if (count >= note.arcTapCounts[tap]!) {
      hide(note, time, tap: tap, immediately: true);
    }
  }

  void consumeSustain(AffEvent note, double start, double end) {
    start = math.max(start, note.start.toDouble());
    end = math.min(end, note.end.toDouble());
    if (start >= end) return;
    final intervals = _held.putIfAbsent(note, () => []);
    var first = 0;
    while (first < intervals.length && intervals[first].end < start - 0.05) {
      first++;
    }
    var last = first;
    while (last < intervals.length && intervals[last].start <= end + 0.05) {
      start = math.min(start, intervals[last].start);
      end = math.max(end, intervals[last].end);
      last++;
    }
    intervals.replaceRange(first, last, [(start: start, end: end)]);
  }

  Iterable<ChartTimeSpan> visibleSustain(
    AffEvent note,
    double start,
    double end,
  ) sync* {
    if (start == end) {
      if (!consumedAt(note, start)) yield (start: start, end: end);
      return;
    }
    for (final interval in _held[note] ?? const <ChartTimeSpan>[]) {
      if (interval.start > end) break;
      if (interval.end <= start) continue;
      if (interval.start > start) yield (start: start, end: interval.start);
      start = math.max(start, interval.end);
      if (start >= end) return;
    }
    if (start < end) yield (start: start, end: end);
  }

  bool consumedAt(AffEvent note, double time) =>
      _held[note]?.any((span) => span.start <= time && time <= span.end) ??
      false;

  void clear() {
    hitEffects.clear();
    earlyHolds.clear();
    _hidden.clear();
    _hitTaps.clear();
    _held.clear();
  }
}

class ChartTimeline {
  ChartTimeline(AffChart chart, {double bpmBase = 120}) {
    final headerEnd = chart.source.indexOf(
      RegExp(r'^\s*-\s*$', multiLine: true),
    );
    final density = headerEnd < 0
        ? null
        : RegExp(
            r'^TimingPointDensityFactor:[ \t]*([^\r\n]+)',
            multiLine: true,
          ).firstMatch(chart.source.substring(0, headerEnd));
    final parsedDensity = double.tryParse(density?.group(1)?.trim() ?? '');
    _sustainDensity =
        parsedDensity != null && parsedDensity.isFinite && parsedDensity > 0
        ? parsedDensity
        : 1;
    scene = ChartScene(chart);
    groupOptions = {
      for (final group in chart.groups)
        group.id: AffGroupOptions(group.attributes),
    };
    final notes = <AffEvent>[];
    final groups = <int, List<AffEvent>>{};
    final timings = <int, List<AffEvent>>{0: []};
    for (final event in chart.events) {
      if (event.kind == AffKind.timing) {
        timings.putIfAbsent(event.group, () => []).add(event);
      } else if (event.isNote) {
        notes.add(event);
        groups.putIfAbsent(event.group, () => []).add(event);
      }
    }
    _notes = _TimedNotes(notes);
    _arcEnds = {
      for (final note in notes)
        if (note.kind == AffKind.arc && note.isSustain && !note.noInput)
          (
            note.group,
            note.number(7),
            note.end,
            note.number(3),
            note.number(6),
          ),
    };
    wideLanes =
        scene.hasLaneEvents ||
        notes.any(
          (note) =>
              (note.kind == AffKind.tap || note.kind == AffKind.hold) &&
              note.groundPosition == null &&
              (note.laneX < 0 || note.laneX > 1),
        );
    for (final list in timings.values) {
      list.sort((a, b) {
        final timeOrder = a.start.compareTo(b.start);
        return timeOrder == 0
            ? a.sourceStart.compareTo(b.sourceStart)
            : timeOrder;
      });
    }
    tempos = timings[0]!;
    _timings = timings;
    final reference = bpmBase.isFinite && bpmBase > 0 ? bpmBase : 120.0;
    _scrolls = timings.map(
      (id, events) => MapEntry(id, ChartScroll(events, reference)),
    );
    _groups = groups.map((id, events) => MapEntry(id, _TimedNotes(events)));
  }

  late final _TimedNotes _notes;
  late final Map<int, _TimedNotes> _groups;
  late final Map<int, ChartScroll> _scrolls;
  late final List<AffEvent> tempos;
  late final Map<int, List<AffEvent>> _timings;
  late final double _sustainDensity;
  late final Set<(int, double, int, double, double)> _arcEnds;
  late final ChartScene scene;
  late final Map<int, AffGroupOptions> groupOptions;
  late final bool wideLanes;
  List<AffEvent> get notes => _notes.events;
  ChartScroll scroll(int group) => _scrolls[group] ?? _scrolls[0]!;
  List<AffEvent> groupTempos(int group) => _timings[group] ?? tempos;

  Iterable<int> automaticSustainCheckpoints(
    AffEvent note, {
    double minimum = double.negativeInfinity,
    double maximum = double.infinity,
  }) => sustainTicks(
    note,
    minimum: minimum,
    maximum: maximum,
  ).map((tick) => tick.time);

  Iterable<({int time, double early})> sustainTicks(
    AffEvent note, {
    double minimum = double.negativeInfinity,
    double maximum = double.infinity,
  }) sync* {
    if (!note.isSustain) return;
    final timings = groupTempos(note.group);
    var low = 0, high = timings.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (timings[mid].start <= note.start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    var bpm =
        (timings.isEmpty ? 120.0 : timings[math.max(0, low - 1)].number(1))
            .abs();
    var start = note.start;
    while (bpm == 0 && low < timings.length && timings[low].start < note.end) {
      final timing = timings[low++];
      bpm = timing.number(1).abs();
      start = math.max(start, timing.start);
    }
    if (bpm == 0) return;
    final interval = math.max(
      1.0,
      (bpm >= 255 ? 60000 : 30000) / bpm / _sustainDensity,
    );
    final isArc = note.kind == AffKind.arc;
    final continued =
        isArc &&
        _arcEnds.contains((
          note.group,
          note.number(7),
          note.start,
          note.number(2),
          note.number(5),
        ));
    final duration = note.end - start;
    final first = continued && start == note.start ? 0 : 1;
    final count = math.max(1, (duration / interval).floor());
    double early(int time) =>
        math.min(interval / 2, (time - start).toDouble()).roundToDouble();
    if (first == 1 && count <= 2) {
      final time = start + duration ~/ 2;
      if (time >= minimum && time <= maximum) {
        yield (time: time, early: early(time));
      }
      return;
    }
    if (maximum < note.start || minimum > note.end) return;
    final begin = minimum.isFinite
        ? math.max(first, ((minimum - start - .5) / interval).ceil())
        : first;
    for (var index = begin; index < count; index++) {
      final time = index == 0 ? start : start + (interval * index).round();
      if (time > maximum || time >= note.end) break;
      if (time >= minimum) {
        yield (time: time, early: early(time));
      }
    }
  }

  bool onJudgementPlane(
    AffEvent note,
    double cursor,
    num at,
    double tolerance, {
    double timeTolerance = 1,
  }) {
    final map = scroll(note.group);
    // A frozen scroll section can put many different timestamps on the wall.
    // Keep those future notes read-only until the cursor reaches their time.
    return (cursor - at).abs() <= timeTolerance &&
        (map.at(cursor) - map.at(at.toDouble())).abs() <= tolerance;
  }

  Iterable<({AffEvent note, double start, double end})> visibleInPerspective(
    double time,
    double near,
    double far, {
    double history = 500,
  }) sync* {
    for (final entry in _groups.entries) {
      final index = entry.value;
      final map = scroll(entry.key);
      final at = map.at(time);
      for (final range in map.visible(
        at + near,
        at + far,
        math.max(time - history, index.events.first.firstTime.toDouble()),
        index.endings.last.toDouble(),
      )) {
        for (final note in index.visible(
          range.start - 1e-5,
          range.end + 1e-5,
        )) {
          final start = math.max(range.start, note.firstTime.toDouble());
          final end = math.min(range.end, note.lastTime.toDouble());
          if (end + 1e-5 < start) continue;
          yield (note: note, start: start, end: math.max(end, start));
        }
      }
    }
  }

  Iterable<({double time, bool downbeat})> beats(double from, double to) sync* {
    for (var index = 0; index < tempos.length; index++) {
      final tempo = tempos[index];
      final end = index + 1 < tempos.length ? tempos[index + 1].start : to + 1;
      if (end <= from || tempo.start > to) continue;
      final bpm = tempo.number(1);
      if (bpm < 1 || bpm > 1500 || tempo.number(2) <= 0) continue;
      final interval = 60000 / bpm;
      final measure = math.max(1, tempo.number(2).round());
      final first = math.max(0, ((from - tempo.start) / interval).ceil());
      for (var beat = first; beat < first + 180; beat++) {
        final time = tempo.start + beat * interval;
        if (time >= end || time > to) break;
        yield (time: time, downbeat: beat % measure == 0);
      }
    }
  }

  Iterable<AffEvent> visible(double from, double to) =>
      _notes.visible(from, to);
}

class _TimedNotes {
  _TimedNotes(this.events) {
    events.sort((a, b) => a.firstTime.compareTo(b.firstTime));
    var end = -0x80000000;
    for (final note in events) {
      end = math.max(end, note.lastTime);
      endings.add(end);
    }
  }

  final List<AffEvent> events;
  final endings = <int>[];

  Iterable<AffEvent> visible(double from, double to) sync* {
    var low = 0;
    var high = endings.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (endings[mid] < from) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var index = low; index < events.length; index++) {
      final note = events[index];
      if (note.firstTime > to) break;
      if (note.lastTime >= from) yield note;
    }
  }
}

class TimelineGeometry {
  const TimelineGeometry(
    this.size,
    this.ms,
    this.lookahead, {
    this.wideLanes = false,
    this.overlay = false,
    this.reverse = false,
  });

  final Size size;
  final double ms, lookahead;
  final bool wideLanes;
  final bool overlay, reverse;
  static const skyMin = -0.5;
  static const skyMax = 1.5;
  static const _arcTapWidthScale = 0.32;
  static const _minArcTapWidth = 28.0;

  double get judgement => size.height * 0.82;
  double get centerGap => size.width * 0.52;
  double get span =>
      size.width *
      (overlay
          ? 0.43
          : wideLanes
          ? 0.28
          : 0.38);
  double get groundStart => wideLanes ? -0.25 : 0;
  double get groundEnd => wideLanes ? 1.25 : 1;
  double get skySpan => overlay
      ? span
      : math.max(
          1.0,
          math.min(
            (size.width - centerGap) / (2 + _arcTapWidthScale),
            (size.width - centerGap - _minArcTapWidth) / 2,
          ),
        );
  double x(double value, {bool airborne = false}) => overlay
      ? size.width * 0.285 +
            (airborne ? value.clamp(skyMin, skyMax) : value) * span
      : airborne
      ? (size.width + centerGap) / 2 +
            (value.clamp(skyMin, skyMax) - 0.5) * skySpan
      : size.width * (wideLanes ? 0.15 : 0.09) + value * span;
  double get _signedLookahead => reverse ? -lookahead : lookahead;
  double y(double time) =>
      judgement - (time - ms) * size.height / _signedLookahead;
  double time(double y) =>
      ms + (judgement - y) * _signedLookahead / size.height;
  Rect arcTapBounds(double value, double height, double at) => Rect.fromCenter(
    center: Offset(x(value, airborne: true), y(at)),
    width: (skySpan * _arcTapWidthScale).clamp(_minArcTapWidth, 76.0),
    height: 8 + height.clamp(0.0, 1.0) * 4,
  );
  double trackX(
    double point, {
    bool airborne = false,
    bool freeGround = false,
  }) {
    final value =
        (point - x(0, airborne: airborne)) / (airborne ? skySpan : span);
    return airborne
        ? value.clamp(skyMin, skyMax)
        : value.clamp(
            freeGround ? AffChart.minGroundX : groundStart,
            freeGround ? AffChart.maxGroundX : groundEnd,
          );
  }

  int lane(double point) =>
      (trackX(point) * 4).floor().clamp(wideLanes ? -1 : 0, wideLanes ? 4 : 3) +
      1;

  AffEvent? nearest(
    ChartTimeline timeline,
    Offset point, {
    ChartLaneMode laneMode = ChartLaneMode.automatic,
  }) => pick(timeline, point, laneMode: laneMode)?.note;

  ChartPick? pick(
    ChartTimeline timeline,
    Offset point, {
    ChartLaneMode laneMode = ChartLaneMode.automatic,
    ChartEditorVisibility visibility = const ChartEditorVisibility(),
  }) {
    final tempoColumn = !overlay && point.dx < x(groundStart);
    final atTime = time(point.dy);
    final airColumn = point.dx >= centerGap;
    var distance = 26.0;
    AffEvent? closest;
    var tapDistance = double.infinity;
    ChartPick? closestTap;
    final radius = (time(point.dy + 26) - atTime).abs();
    for (final event in timeline.visible(atTime - radius, atTime + radius)) {
      if (!laneMode.showsAt(timeline, event, ms)) continue;
      if (tempoColumn && event.groundPosition == null) continue;
      for (final tap in event.arcTaps) {
        if ((!overlay && !airColumn) || !visibility.shows(event, tap: tap)) {
          continue;
        }
        final p = event.point(tap.toDouble());
        final bounds = arcTapBounds(p.x, p.height, tap.toDouble());
        final candidate = (bounds.center - point).distanceSquared;
        if (candidate < tapDistance && bounds.inflate(2).contains(point)) {
          tapDistance = candidate;
          closestTap = (note: event, tap: event.standaloneSky ? null : tap);
        }
      }
      if (!visibility.shows(event)) continue;
      final isAir = event.kind == AffKind.arc || event.kind == AffKind.flick;
      if (!overlay && isAir != airColumn) continue;
      final at = atTime.clamp(
        event.firstTime.toDouble(),
        event.lastTime.toDouble(),
      );
      final noteX = event.kind == AffKind.arc && event.start == event.end
          ? trackX(point.dx, airborne: true)
                .clamp(
                  math.min(event.number(2), event.number(3)),
                  math.max(event.number(2), event.number(3)),
                )
                .toDouble()
          : isAir
          ? event.point(at).x
          : event.laneX;
      final target = Offset(x(noteX, airborne: isAir), y(at));
      final candidate = (target - point).distance;
      if (candidate < distance) {
        distance = candidate;
        closest = event;
      }
    }
    if (closestTap != null) return closestTap;
    if (closest != null) return (note: closest, tap: null);
    if (!tempoColumn) return null;
    distance = 18;
    for (final tempo in timeline.tempos) {
      if (!visibility.shows(tempo)) continue;
      final candidate = (y(tempo.start.toDouble()) - point.dy).abs();
      if (candidate < distance) {
        closest = tempo;
        distance = candidate;
      }
    }
    return closest == null ? null : (note: closest, tap: null);
  }
}

class ChartTimelinePainter extends CustomPainter {
  ChartTimelinePainter(
    this.timeline,
    this.position,
    this.lookahead, {
    this.visibility,
    this.handles = const [],
    this.dragPath = const [],
    this.snapPoint,
    this.skin = ChartSkin.defaults,
    this.preview = false,
    this.overlay = false,
    this.laneMode = ChartLaneMode.automatic,
    this.judgement,
    this.noteOpacity = 1,
    this.appearance = defaultChartAppearance,
    this.reverse = false,
    this.frozenAt,
    this.practiceSegment,
  }) : super(repaint: position);

  final ChartTimeline timeline;
  final ValueNotifier<double> position;
  final double lookahead;
  final double? frozenAt;
  final ChartPracticeSegment? practiceSegment;
  final bool reverse;
  final ChartEditorVisibility? visibility;
  final List<({int time, double x, double height})> handles;
  final List<Offset> dragPath;
  final Offset? snapPoint;
  final ChartSkin skin;
  final bool preview;
  final bool overlay;
  final ChartLaneMode laneMode;
  final ChartAppearance appearance;
  final ChartJudgement? judgement;
  final double noteOpacity;

  static const groundColor = Color(0xFF65D6C6);
  static const airColor = Color(0xFFFFCB7D);
  static Color arcColor(AffEvent note) => note.designant
      ? const Color(0xFFFB5464)
      : note.trace
      ? chartTraceColor
      : chartArcColors[note.number(7).toInt() % chartArcColors.length];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final clock = position.value;
    final time = frozenAt ?? clock;
    final g = TimelineGeometry(
      size,
      time,
      lookahead,
      wideLanes: laneMode.expansion(timeline, clock) > 0,
      overlay: overlay,
      reverse: reverse,
    );
    final paint = Paint()..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    skin.paintBackground(canvas, size, flat: true);
    for (final air in [false, if (!overlay) true]) {
      final bounds = Rect.fromLTRB(
        g.x(air ? TimelineGeometry.skyMin : g.groundStart, airborne: air),
        0,
        g.x(air ? TimelineGeometry.skyMax : g.groundEnd, airborne: air),
        size.height,
      );
      canvas.drawRect(
        bounds,
        paint..color = air ? const Color(0xC8222845) : const Color(0xD5222D47),
      );
      final track = air ? null : skin[ChartSprite.track];
      if (track != null) {
        final start = (g.time(0) / (reverse ? -360 : 360)) % 1;
        track.strip(
          canvas,
          [
            bounds.topLeft,
            bounds.topRight,
            bounds.bottomLeft,
            bounds.bottomRight,
          ],
          alpha: 0.50,
          start: start,
          end: start - lookahead / 360,
        );
      }
      for (
        var lane = air ? 0 : (g.groundStart * 4).round();
        lane <= (air ? 4 : (g.groundEnd * 4).round());
        lane++
      ) {
        final x = g.x(lane / 4, airborne: air);
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          paint..color = const Color(0x907E90B0),
        );
      }
      final label = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: overlay
              ? '地轨与空轨'
              : air
              ? '空轨'
              : '地轨',
          style: TextStyle(color: air ? airColor : groundColor, fontSize: 12),
        ),
      )..layout();
      label.paint(canvas, Offset(g.x(0, airborne: air) + 5, size.height - 21));
      label.dispose();
    }

    final topTime = g.time(0);
    final bottomTime = g.time(size.height);
    final from = math.min(topTime, bottomTime);
    final to = math.max(topTime, bottomTime);
    final tempos = timeline.tempos;
    for (var index = 0; index < tempos.length; index++) {
      final tempo = tempos[index];
      if (visibility?.shows(tempo) == false) continue;
      final end = index + 1 < tempos.length
          ? tempos[index + 1].start.toDouble()
          : to + 1;
      if (end < from || tempo.start > to) continue;
      if (tempo.start >= from) {
        final label = TextPainter(
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
          text: TextSpan(
            text: tempo.number(1).toStringAsFixed(1),
            style: TextStyle(
              color: visibility?.selected(tempo) == true
                  ? Colors.white
                  : airColor,
              fontSize: 10,
            ),
          ),
        )..layout(maxWidth: math.max(1, g.x(g.groundStart) - 8));
        label.paint(
          canvas,
          Offset(4, g.y(tempo.start.toDouble()) - label.height / 2),
        );
        label.dispose();
      }
    }
    for (final beat in timeline.beats(from, to)) {
      final y = g.y(beat.time);
      canvas.drawLine(
        Offset(g.x(g.groundStart), y),
        Offset(g.x(TimelineGeometry.skyMax, airborne: true), y),
        paint
          ..color = beat.downbeat
              ? const Color(0xFF53667B)
              : const Color(0xFF2B394A),
      );
    }

    final segment = practiceSegment;
    final visible = timeline
        .visible(from - 80, to + 80)
        .where((note) => segment == null || segment.shows(note));
    final notes = overlay
        ? [
            ...visible.where((note) => !note.isAir),
            ...visible.where((note) => note.isAir),
          ]
        : visible;
    final stacks = ChartStackLabels();
    if (appearance.trace > 0) {
      final chords = <int, List<ChartChordPoint>>{};
      for (final note in notes) {
        if (note.noInput ||
            note.designant ||
            !laneMode.showsAt(timeline, note, clock)) {
          continue;
        }
        final opacity =
            noteOpacity *
            (preview ? timeline.scene.groupOpacity(note.group, clock) : 1);
        if (opacity <= 0) continue;
        for (final (at, tap) in chartChordTaps(note)) {
          if ((segment != null && !segment.includes(at)) ||
              (note.isAir && appearance.arcTap == 0) ||
              visibility?.shows(note, tap: tap) == false ||
              judgement?.hidden(note, clock, tap: tap) == true) {
            continue;
          }
          final y = g.y(at.toDouble());
          if (y < -20 || y > size.height + 20 || (!reverse && at < g.ms - 16)) {
            continue;
          }
          final x = note.variableArcTap
              ? (g.x(note.number(2), airborne: true) +
                        g.x(note.number(3), airborne: true)) /
                    2
              : note.isAir
              ? g.x(note.point(at.toDouble()).x, airborne: true)
              : g.x(note.laneX);
          (chords[at] ??= []).add((
            point: Offset(x, y),
            air: note.isAir,
            opacity: opacity,
            depth: at.toDouble(),
          ));
        }
      }
      paintChartChords(canvas, chords.values, appearance.trace);
    }
    for (final note in notes) {
      if (!laneMode.showsAt(timeline, note, clock)) {
        continue;
      }
      final bodyHidden =
          (segment != null && !segment.showsBody(note)) ||
          visibility?.shows(note) == false ||
          judgement?.hidden(note, clock) == true;
      if (bodyHidden && note.arcTaps.isEmpty) continue;
      final isSelected = visibility?.selected(note) == true;
      final color = switch (note.kind) {
        AffKind.arc => arcColor(note),
        AffKind.flick => airColor,
        _ => groundColor,
      };
      final opacity =
          noteOpacity *
          (preview ? timeline.scene.groupOpacity(note.group, clock) : 1.0);
      if (opacity == 0) continue;
      paint.color = isSelected
          ? Colors.white
          : color.withValues(alpha: opacity * (note.noInput ? 0.30 : 0.92));
      final alpha = paint.color.a;
      final y = g.y(note.start.toDouble());
      if (note.kind == AffKind.arc) {
        final color = paint.color;
        final bodyAlpha =
            alpha *
            (note.trace
                ? chartTraceOpacity * appearance.trace
                : appearance.snake);
        final above = g.time(-20), below = g.time(size.height + 20);
        final first = math.max(
          math.max(
            note.firstTime.toDouble(),
            segment?.start ?? double.negativeInfinity,
          ),
          math.min(above, below),
        );
        final last = math.min(
          math.min(note.lastTime.toDouble(), segment?.end ?? double.infinity),
          math.max(above, below),
        );
        if (last < first) continue;
        final instant = note.start == note.end;
        final texture = note.trace || instant || isSelected
            ? null
            : skin.snakeTexture(note.number(7).toInt());
        final snakeHalfWidth = (g.skySpan * chartArcHalfWidth).clamp(5.5, 19.0);
        final guide = !preview && visibility?.showsGuide(note) == true;
        if (!bodyHidden && !note.variableArcTap && (bodyAlpha > 0 || guide)) {
          final spans =
              judgement?.visibleSustain(note, first, last) ??
              [(start: first, end: last)];
          for (final span in spans) {
            if (!note.trace && span.start == note.start) {
              stacks.add(
                note,
                Offset(g.x(note.number(2), airborne: true), y),
                selected: isSelected,
              );
            }
            final segments =
                ((g.y(span.start) - g.y(span.end)).abs() * note.smoothness / 9)
                    .ceil()
                    .clamp(1, 100);
            final path = Path();
            final points = <Offset>[];
            for (var step = 0; step <= segments; step++) {
              final fraction = step / segments;
              final time = span.start + (span.end - span.start) * fraction;
              final point = instant
                  ? note.arcPoint(fraction)
                  : note.point(time);
              final x = g.x(point.x, airborne: true);
              final y = g.y(time);
              if (texture != null) points.add(Offset(x, y));
              if (step == 0) {
                path.moveTo(x, y);
              } else {
                path.lineTo(x, y);
              }
            }
            if (bodyAlpha > 0 && texture != null) {
              final uvUnit = math.min(
                350.0,
                (note.lastTime - note.firstTime).toDouble(),
              );
              texture.strip(
                canvas,
                [
                  for (var i = 0; i < points.length; i++)
                    ..._arcStripPair(points, i, snakeHalfWidth),
                ],
                alpha: bodyAlpha,
                start: (span.start - note.firstTime) / uvUnit,
                end: (span.end - note.firstTime) / uvUnit,
              );
            } else if (bodyAlpha > 0) {
              canvas.drawPath(
                path,
                paint
                  ..style = PaintingStyle.stroke
                  ..color = color.withValues(alpha: bodyAlpha)
                  ..strokeWidth = note.trace
                      ? (isSelected ? 5 : 3.5)
                      : snakeHalfWidth * 2 + (isSelected ? 2 : 0),
              );
              paint.style = PaintingStyle.fill;
            }
            if (guide) {
              canvas.drawPath(
                path,
                paint
                  ..style = PaintingStyle.stroke
                  ..color = const Color(
                    0xFFFFE3A2,
                  ).withValues(alpha: appearance.trace * 0.92)
                  ..strokeWidth = 1.5,
              );
              paint.style = PaintingStyle.fill;
            }
          }
        }
        final tapAlpha = alpha * appearance.arcTap;
        if (!bodyHidden && note.variableArcTap && tapAlpha > 0) {
          final left = g.x(
            math.min(note.number(2), note.number(3)),
            airborne: true,
          );
          final right = g.x(
            math.max(note.number(2), note.number(3)),
            airborne: true,
          );
          final bounds = Rect.fromLTRB(left - 4, y - 5, right + 4, y + 5);
          stacks.add(note, bounds.center, selected: isSelected);
          final tapTexture = isSelected ? null : skin[ChartSprite.arcTap];
          if (tapTexture != null) {
            tapTexture.draw(canvas, bounds, alpha: tapAlpha);
          } else {
            canvas.drawRRect(
              RRect.fromRectAndRadius(bounds, const Radius.circular(3)),
              paint..color = color.withValues(alpha: tapAlpha),
            );
          }
        }
        for (final tap in note.arcTapCounts.keys) {
          if (appearance.arcTap == 0) break;
          if (segment != null && !segment.includes(tap)) continue;
          if (visibility?.shows(note, tap: tap) == false) continue;
          if (judgement?.hidden(note, clock, tap: tap) == true) continue;
          if (tap < first - 30 || tap > last + 30) continue;
          final point = note.point(tap.toDouble());
          final bounds = g.arcTapBounds(point.x, point.height, tap.toDouble());
          final tapSelected = visibility?.selected(note, tap: tap) == true;
          stacks.add(
            note,
            bounds.center,
            tap: tap,
            count:
                judgement?.remainingTaps(note, tap, clock) ??
                note.arcTapCounts[tap]!,
            selected: tapSelected,
          );
          final tapAlpha =
              appearance.arcTap *
              (tapSelected ? 1.0 : opacity * (note.noInput ? 0.30 : 0.92));
          final texture = tapSelected
              ? null
              : skin[note.designant
                    ? ChartSprite.designant
                    : ChartSprite.arcTap];
          if (texture != null) {
            texture.draw(canvas, bounds, alpha: tapAlpha);
          } else {
            canvas.drawRRect(
              RRect.fromRectAndRadius(bounds, const Radius.circular(3)),
              paint
                ..color = (tapSelected ? Colors.white : color).withValues(
                  alpha: tapAlpha,
                ),
            );
          }
        }
      } else if (note.kind == AffKind.flick) {
        final point = note.point(note.start.toDouble());
        final center = Offset(g.x(point.x, airborne: true), y);
        stacks.add(note, center, selected: isSelected);
        final texture = isSelected ? null : skin[ChartSprite.flick];
        if (texture != null) {
          texture.draw(
            canvas,
            Rect.fromCenter(center: center, width: 18, height: 14),
            alpha: alpha,
          );
        } else {
          canvas.drawPath(
            Path()..addPolygon([
              center.translate(-7, 4),
              center.translate(0, -7),
              center.translate(7, 4),
            ], true),
            paint,
          );
        }
        paintFlickArrow(
          canvas,
          center,
          Offset(note.number(3), -note.number(4)),
          17,
          alpha,
        );
      } else {
        final x = g.x(note.laneX);
        final halfWidth = (g.span * 0.094).clamp(3.0, 30.0);
        final hold = note.kind == AffKind.hold;
        final end = math.min(
          note.end.toDouble(),
          segment?.end ?? double.infinity,
        );
        final spans = hold && judgement != null
            ? judgement!.visibleSustain(note, note.start.toDouble(), end)
            : [(start: note.start.toDouble(), end: end)];
        final texture = isSelected
            ? null
            : skin[hold ? ChartSprite.hold : ChartSprite.tap];
        for (final span in spans) {
          final extend =
              hold &&
              span.start == note.start &&
              clock < note.start &&
              g.ms < span.start &&
              judgement?.earlyHolds.contains(note) == true;
          final start = extend ? g.ms : span.start;
          final topAt = reverse ? start : span.end;
          final bottomAt = reverse ? span.end : start;
          final top =
              g.y(topAt) - (topAt == (reverse ? note.start : note.end) ? 4 : 0);
          final bottom =
              g.y(bottomAt) +
              (bottomAt == (reverse ? note.end : note.start) ? 4 : 0);
          if (top > size.height + 8 || bottom < -8) continue;
          final bounds = Rect.fromLTRB(
            x - halfWidth,
            top,
            x + halfWidth,
            bottom,
          );
          if (span.start == note.start) {
            stacks.add(note, Offset(x, y), selected: isSelected);
          }
          if (texture != null) {
            final duration = math.max(1, note.end - note.start);
            texture.draw(
              canvas,
              bounds,
              alpha: alpha,
              fromY: hold ? (note.end - span.end) / duration : 0,
              toY: hold ? (note.end - span.start) / duration : 1,
              flipY: hold && reverse,
            );
          } else {
            canvas.drawRRect(
              RRect.fromRectAndRadius(bounds, const Radius.circular(4)),
              paint,
            );
          }
        }
      }
    }
    Offset? previous;
    for (final handle in handles) {
      final point = Offset(
        g.x(handle.x, airborne: true),
        g.y(handle.time.toDouble()),
      );
      if (previous != null) {
        canvas.drawLine(
          previous,
          point,
          paint
            ..color = const Color(0xFFFFD670)
            ..strokeWidth = 2,
        );
      }
      canvas.drawCircle(point, 5, paint..color = const Color(0xFFFFD670));
      previous = point;
    }
    if (dragPath.length > 1) {
      canvas.drawPath(
        Path()..addPolygon(dragPath, false),
        Paint()
          ..color = const Color(0xFFFFD670)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (final air in [false, if (!overlay) true]) {
      final texture = skin[air ? ChartSprite.skyLine : ChartSprite.judgement];
      texture?.draw(
        canvas,
        Rect.fromLTRB(
          g.x(air ? TimelineGeometry.skyMin : g.groundStart, airborne: air),
          g.judgement - 5,
          g.x(air ? TimelineGeometry.skyMax : g.groundEnd, airborne: air),
          g.judgement + 5,
        ),
      );
    }
    canvas.drawLine(
      Offset(
        g.x(overlay ? TimelineGeometry.skyMin : g.groundStart),
        g.judgement,
      ),
      Offset(g.x(TimelineGeometry.skyMax, airborne: true), g.judgement),
      paint
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    if (snapPoint case final point?) drawChartSnapPoint(canvas, point);
    stacks.paint(canvas, size);
    drawChartHits(
      canvas,
      skin,
      judgement,
      clock,
      (hit) => Offset(g.x(hit.x, airborne: hit.air), g.judgement),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChartTimelinePainter oldDelegate) =>
      appearance != oldDelegate.appearance ||
      timeline != oldDelegate.timeline ||
      visibility != oldDelegate.visibility ||
      handles != oldDelegate.handles ||
      dragPath != oldDelegate.dragPath ||
      snapPoint != oldDelegate.snapPoint ||
      preview != oldDelegate.preview ||
      overlay != oldDelegate.overlay ||
      laneMode != oldDelegate.laneMode ||
      judgement != oldDelegate.judgement ||
      noteOpacity != oldDelegate.noteOpacity ||
      skin != oldDelegate.skin ||
      lookahead != oldDelegate.lookahead ||
      reverse != oldDelegate.reverse ||
      frozenAt != oldDelegate.frozenAt ||
      practiceSegment != oldDelegate.practiceSegment ||
      position != oldDelegate.position;
}

const chartTraceColor = Color(0xFFD5BCF9);
const chartTraceOpacity = .48;

class ChartStackLabels {
  final _labels =
      <(AffKind, int, int, int), ({Offset center, int count, bool selected})>{};

  void add(
    AffEvent note,
    Offset center, {
    int? tap,
    int count = 1,
    required bool selected,
  }) {
    if (!center.isFinite || count == 0) return;
    final key = (
      note.kind,
      tap ?? note.start,
      (center.dx * 2).round(),
      (center.dy * 2).round(),
    );
    final prior = _labels[key];
    _labels[key] = (
      center: center,
      count: (prior?.count ?? 0) + count,
      selected: selected || prior?.selected == true,
    );
  }

  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final (:center, :count, :selected) in _labels.values) {
      if (count < 2 || !(Offset.zero & size).inflate(8).contains(center)) {
        continue;
      }
      if (selected) {
        canvas.drawCircle(
          center,
          10,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFFFFD670),
        );
      }
      final text = TextPainter(
        text: TextSpan(
          text: 'x$count',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final label = Rect.fromLTWH(
        (center.dx + 12).clamp(1.0, math.max(1.0, size.width - text.width - 8)),
        (center.dy - text.height - 4).clamp(
          1.0,
          math.max(1.0, size.height - text.height - 4),
        ),
        text.width + 6,
        text.height + 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(label, const Radius.circular(4)),
        paint
          ..style = PaintingStyle.fill
          ..color = const Color(0xE5302348),
      );
      text.paint(canvas, label.topLeft.translate(3, 1));
      text.dispose();
    }
  }
}

typedef ChartChordPoint = ({
  Offset point,
  bool air,
  double opacity,
  double depth,
});

Iterable<(int, int?)> chartChordTaps(AffEvent note) sync* {
  if (note.kind == AffKind.tap || note.variableArcTap) {
    yield (note.start, null);
  }
  for (final tap in note.arcTaps.toSet()) {
    yield (tap, tap);
  }
}

void paintChartChords(
  Canvas canvas,
  Iterable<List<ChartChordPoint>> chords,
  double opacity, {
  double depthTolerance = 0,
}) {
  final paint = Paint()
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round;
  for (final notes in chords) {
    if (notes.length < 2 || !notes.any((note) => note.air)) continue;
    for (var i = 0; i < notes.length - 1; i++) {
      final a = notes[i];
      for (var j = i + 1; j < notes.length; j++) {
        final b = notes[j];
        if (!a.air && !b.air ||
            (a.depth - b.depth).abs() > depthTolerance ||
            (a.point - b.point).distanceSquared < 1) {
          continue;
        }
        canvas.drawLine(
          a.point,
          b.point,
          paint
            ..color = chartTraceColor.withValues(
              alpha:
                  chartTraceOpacity * opacity * math.min(a.opacity, b.opacity),
            ),
        );
      }
    }
  }
}

void drawChartSnapPoint(Canvas canvas, Offset point) {
  final paint = Paint();
  canvas.drawCircle(point, 9, paint..color = const Color(0xFF142332));
  canvas.drawCircle(
    point,
    7,
    paint
      ..color = const Color(0xFF68EAD0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
}

List<Offset> _arcStripPair(List<Offset> points, int index, double halfWidth) {
  final tangent =
      points[math.min(points.length - 1, index + 1)] -
      points[math.max(0, index - 1)];
  final length = tangent.distance;
  final normal = length < 1e-6
      ? Offset(halfWidth, 0)
      : Offset(-tangent.dy, tangent.dx) * (halfWidth / length);
  return [points[index] - normal, points[index] + normal];
}

void paintFlickArrow(
  Canvas canvas,
  Offset center,
  Offset direction,
  double length,
  double opacity,
) {
  if (direction.distance < 1e-6) return;
  final unit = direction / direction.distance;
  final side = Offset(-unit.dy, unit.dx);
  final start = center - unit * (length * 0.35);
  final tip = start + unit * length;
  final rear = tip - unit * (length * 0.3);
  final paint = Paint()
    ..color = Colors.white.withValues(alpha: opacity)
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(start, tip, paint);
  canvas.drawLine(tip, rear + side * (length * 0.2), paint);
  canvas.drawLine(tip, rear - side * (length * 0.2), paint);
}

void drawChartHits(
  Canvas canvas,
  ChartSkin skin,
  ChartJudgement? judgement,
  double time,
  Offset Function(ChartHit) project, {
  double horizontalScale = 1,
}) {
  if (judgement == null) return;
  for (final hit in judgement.hitEffects.reversed) {
    final progress = (time - hit.at) / ChartJudgement.duration;
    if (progress >= 1 || progress < 0) continue;
    final opacity = 1 - progress;
    final center = project(hit);
    final radius = 12 + math.min(hit.count - 1, 3) * 3 + progress * 30;
    if (horizontalScale != 1) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(horizontalScale, 1);
      canvas.translate(-center.dx, -center.dy);
    }
    final paint = Paint()
      ..color = const Color(0xFFFFE4A4).withValues(alpha: opacity)
      ..strokeWidth = 1.5 + opacity * 2
      ..style = PaintingStyle.stroke;
    skin[ChartSprite.hitEffect]?.draw(
      canvas,
      Rect.fromCircle(center: center, radius: radius * 1.4),
      alpha: opacity,
    );
    canvas.drawCircle(center, radius, paint);
    for (var ray = 0; ray < 6; ray++) {
      final angle = ray * math.pi / 3 + 0.25;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * radius * 0.8,
        center + direction * radius * 1.25,
        paint,
      );
    }
    if (horizontalScale != 1) canvas.restore();
  }
}
