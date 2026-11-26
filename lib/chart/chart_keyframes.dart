import 'aff_chart.dart';
import 'chart_arc_editor.dart';

enum ChartKeyframeKind { start, end, tap, wideStart, wideEnd }

typedef ChartKeyframe = ({AffEvent note, ChartKeyframeKind kind, int time});

extension ChartKeyframeProperties on ChartKeyframe {
  bool get arcEndpoint =>
      note.start != note.end &&
      (kind == ChartKeyframeKind.start || kind == ChartKeyframeKind.end);

  bool get airTap => switch (kind) {
    ChartKeyframeKind.tap ||
    ChartKeyframeKind.wideStart ||
    ChartKeyframeKind.wideEnd => true,
    _ => false,
  };

  ({double x, double height}) get position => switch (kind) {
    ChartKeyframeKind.start ||
    ChartKeyframeKind.wideStart => (x: note.number(2), height: note.number(5)),
    ChartKeyframeKind.end ||
    ChartKeyframeKind.wideEnd => (x: note.number(3), height: note.number(6)),
    ChartKeyframeKind.tap => note.point(time.toDouble()),
  };
}

Iterable<ChartKeyframe> chartKeyframes(AffEvent note) sync* {
  if (note.kind != AffKind.arc) return;
  if (note.variableArcTap) {
    yield (note: note, kind: ChartKeyframeKind.wideStart, time: note.start);
    yield (note: note, kind: ChartKeyframeKind.wideEnd, time: note.end);
  } else if (note.start != note.end ||
      (note.arcTaps.isEmpty && note.number(2) != note.number(3))) {
    yield (note: note, kind: ChartKeyframeKind.start, time: note.start);
    yield (note: note, kind: ChartKeyframeKind.end, time: note.end);
  }
  for (final tap in note.arcTaps.toSet()) {
    yield (note: note, kind: ChartKeyframeKind.tap, time: tap);
  }
}

Iterable<ChartKeyframe> chartJoinedEndpoints(
  AffChart chart,
  ChartKeyframe key,
) sync* {
  if (!key.arcEndpoint && !key.isTapAtArcEndpoint) return;
  final position = key.position;
  for (final note in chart.events) {
    if (note.kind != AffKind.arc ||
        note.group != key.note.group ||
        note.start == note.end) {
      continue;
    }
    for (final end in chartKeyframes(note)) {
      if (!end.arcEndpoint || end.time != key.time) continue;
      final point = end.position;
      if ((point.x - position.x).abs() < 1e-6 &&
          (point.height - position.height).abs() < 1e-6) {
        yield end;
      }
    }
  }
}

extension on ChartKeyframe {
  bool get isTapAtArcEndpoint =>
      kind == ChartKeyframeKind.tap &&
      note.start != note.end &&
      (time == note.start || time == note.end);
}

bool canMoveChartEndpoints(Iterable<ChartKeyframe> endpoints, int time) {
  for (final endpoint in endpoints) {
    if (time == endpoint.time) continue;
    final note = endpoint.note;
    final start = endpoint.kind == ChartKeyframeKind.start ? time : note.start;
    final end = endpoint.kind == ChartKeyframeKind.end ? time : note.end;
    if (start == end || (start < end) != (note.start < note.end)) return false;
    final min = start < end ? start : end;
    final max = start < end ? end : start;
    if (note.arcTaps.any((tap) => tap < min || tap > max)) return false;
  }
  return time.abs() <= 0x7fffffff;
}

String moveChartKeyframe(
  AffChart chart,
  ChartKeyframe key,
  double x,
  double height, {
  int? time,
  Iterable<ChartKeyframe>? linkedEndpoints,
}) {
  final note = key.note;
  final point = key.position;
  final atTime = key.arcEndpoint ? time ?? key.time : key.time;
  if (atTime == key.time &&
      (x - point.x).abs() < 1e-6 &&
      (height - point.height).abs() < 1e-6) {
    return chart.source;
  }
  String statement(List<String> args, List<int> taps) {
    final suffix = taps.isEmpty
        ? ''
        : '[${taps.map((at) => 'arctap($at)').join(',')}]';
    return 'arc(${args.join(',')})$suffix;';
  }

  if (key.arcEndpoint || key.isTapAtArcEndpoint) {
    final joined = linkedEndpoints ?? chartJoinedEndpoints(chart, key).toList();
    if (!canMoveChartEndpoints(joined, atTime)) return chart.source;
    return chart.replaceEvents({
      for (final endpoint in joined)
        endpoint.note: statement(
          endpoint.note.arguments.toList()
            ..[endpoint.kind == ChartKeyframeKind.start ? 0 : 1] = atTime
                .toString()
            ..[endpoint.kind == ChartKeyframeKind.start ? 2 : 3] = x.toString()
            ..[endpoint.kind == ChartKeyframeKind.start ? 5 : 6] = height
                .toString(),
          endpoint.note.arcTaps,
        ),
    });
  }

  void setEnd(List<String> args, {required bool start}) {
    final xIndex = start ? 2 : 3;
    final heightIndex = start ? 5 : 6;
    if (x != point.x) args[xIndex] = x.toString();
    if (height != point.height) args[heightIndex] = height.toString();
  }

  if (key.kind == ChartKeyframeKind.tap &&
      note.firstTime < key.time &&
      key.time < note.lastTime) {
    final left = note.arguments.toList()..[1] = '${key.time}';
    final right = note.arguments.toList()..[0] = '${key.time}';
    left[3] = right[2] = x.toString();
    left[6] = right[5] = height.toString();
    bool firstHalf(int at) =>
        note.start < note.end ? at < key.time : at > key.time;
    return chart.replace(
      note,
      [
        statement(left, note.arcTaps.where(firstHalf).toList()),
        statement(right, note.arcTaps.where((at) => !firstHalf(at)).toList()),
      ].join(chart.newline),
    );
  }
  final at = key.kind == ChartKeyframeKind.tap
      ? key.time.clamp(note.firstTime, note.lastTime)
      : key.time;

  final related = ArcDraft.connected(chart, note);
  final replacements = <AffEvent, String>{};
  for (final event in related.isEmpty ? [note] : related) {
    final args = event.arguments.toList();
    final separateEnds =
        note.start == note.end && key.kind != ChartKeyframeKind.tap;
    if (event.start == at &&
        (!separateEnds ||
            key.kind == ChartKeyframeKind.wideStart ||
            key.kind == ChartKeyframeKind.start)) {
      setEnd(args, start: true);
    }
    if (event.end == at &&
        (!separateEnds ||
            key.kind == ChartKeyframeKind.wideEnd ||
            key.kind == ChartKeyframeKind.end)) {
      setEnd(args, start: false);
    }
    if (args.join(',') != event.arguments.join(',')) {
      replacements[event] = statement(args, event.arcTaps);
    }
  }
  return chart.replaceEvents(replacements);
}
