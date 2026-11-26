import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_perspective.dart';
import 'chart_timeline.dart';

enum ChartHitKind {
  tap('地键'),
  hold('长按'),
  arc('蛇'),
  sky('天键');

  const ChartHitKind(this.label);
  final String label;
}

enum ChartHitShape {
  oval('圆形／椭圆'),
  square('方框'),
  rectangle('长方形'),
  lane('沿轨道'),
  quadrilateral('自定义四边形');

  const ChartHitShape(this.label);
  final String label;
}

class ChartHitArea {
  const ChartHitArea({
    required this.shape,
    this.width = 1,
    this.height = 1,
    this.forward = 1,
    this.backward = 1,
    this.vertices = const [
      Offset(-1, -1),
      Offset(1, -1),
      Offset(1, 1),
      Offset(-1, 1),
    ],
  });

  final ChartHitShape shape;
  final double width, height, forward, backward;
  final List<Offset> vertices;

  static ChartHitArea defaults(ChartHitKind kind) => ChartHitArea(
    shape: switch (kind) {
      ChartHitKind.tap || ChartHitKind.hold => ChartHitShape.lane,
      _ => ChartHitShape.oval,
    },
  );

  ChartHitArea copyWith({
    ChartHitShape? shape,
    double? width,
    double? height,
    double? forward,
    double? backward,
    List<Offset>? vertices,
  }) => ChartHitArea(
    shape: shape ?? this.shape,
    width: width ?? this.width,
    height: height ?? this.height,
    forward: forward ?? this.forward,
    backward: backward ?? this.backward,
    vertices: vertices == null ? this.vertices : List.unmodifiable(vertices),
  );
}

String encodeChartHitAreas(Map<ChartHitKind, ChartHitArea> areas) =>
    jsonEncode({
      for (final entry in areas.entries)
        entry.key.name: {
          'shape': entry.value.shape.name,
          'width': entry.value.width,
          'height': entry.value.height,
          'forward': entry.value.forward,
          'backward': entry.value.backward,
          'vertices': [
            for (final p in entry.value.vertices) [p.dx, p.dy],
          ],
        },
    });

Map<ChartHitKind, ChartHitArea> decodeChartHitAreas(String? data) {
  if (data == null) return {};
  final result = <ChartHitKind, ChartHitArea>{};
  double number(Object? value, double fallback, {double min = .05}) =>
      value is num && value.isFinite
      ? value.toDouble().clamp(min, 8.0)
      : fallback;
  try {
    final raw = jsonDecode(data);
    if (raw is! Map) return result;
    for (final kind in ChartHitKind.values) {
      final item = raw[kind.name];
      if (item is! Map) continue;
      final defaults = ChartHitArea.defaults(kind);
      final points = item['vertices'];
      result[kind] = ChartHitArea(
        shape:
            ChartHitShape.values
                .where((s) => s.name == item['shape'])
                .firstOrNull ??
            defaults.shape,
        width: number(item['width'], 1),
        height: number(item['height'], 1),
        forward: number(item['forward'], 1),
        backward: number(item['backward'], 1),
        vertices:
            points is List &&
                points.length == 4 &&
                points.every((p) => p is List && p.length == 2)
            ? [
                for (final p in points.cast<List>())
                  Offset(number(p[0], 0, min: -8), number(p[1], 0, min: -8)),
              ]
            : defaults.vertices,
      );
    }
  } on FormatException {
    return {};
  }
  return result;
}

/// One note's judgement-plane geometry in screen coordinates before horizontal
/// camera stretching. Both the editor and live input use the same projection.
class ChartHitFrame {
  ChartHitFrame._({
    required this.center,
    required this.radius,
    required this.ovalAxisStart,
    required this.ovalAxisEnd,
    required this.endRadius,
    required this.wall,
    required this.back,
    required this.front,
    this.perspective,
  });

  final Offset center, ovalAxisStart, ovalAxisEnd;
  final double radius, endRadius;
  final (Offset, Offset) wall, back, front;
  final PerspectiveGeometry? perspective;

  double get forwardLength =>
      math.max(1, (center - (front.$1 + front.$2) / 2).distance);
  double get backwardLength =>
      math.max(1, (center - (back.$1 + back.$2) / 2).distance);
  double get laneHalfWidth => math.max(1, (wall.$2 - wall.$1).distance / 2);
  Offset get laneForward {
    final delta = (front.$1 + front.$2) / 2 - center;
    return delta.distance > .001 ? delta / delta.distance : const Offset(0, -1);
  }

  Offset get laneAcross {
    final delta = wall.$2 - wall.$1;
    return delta.distance > .001 ? delta / delta.distance : const Offset(1, 0);
  }

  Offset toScreen(Offset point) =>
      perspective?.stretchHorizontal(point) ?? point;
  Offset fromScreen(Offset point) =>
      perspective?.baseHorizontal(point) ?? point;

  static ChartHitFrame? ground(
    double lane, {
    PerspectiveGeometry? space,
    TimelineGeometry? flat,
    double widening = 0,
    bool free = false,
  }) {
    const halfLane = .14;
    if (space != null) {
      final left = free
          ? lane - halfLane
          : math.max(lane - halfLane, -.25 * widening - .02);
      final right = free
          ? lane + halfLane
          : math.min(lane + halfLane, 1 + .25 * widening + .02);
      if (left >= right) return null;
      Offset project(double x, double depth) =>
          space.baseHorizontal(space.project(x, 0, depth));
      final center = project(lane, space.time);
      final width =
          (project(lane + .112, space.time) - project(lane - .112, space.time))
              .distance;
      final far = project(lane, space.far);
      final ratio = (width * 3 / math.max(1, (far - center).distance)).clamp(
        0.0,
        1.0,
      );
      final wall = (project(left, space.time), project(right, space.time));
      return ChartHitFrame._(
        center: center,
        radius: math.max(1, width / 2),
        ovalAxisStart: center,
        ovalAxisEnd: center,
        endRadius: math.max(1, width / 2),
        wall: wall,
        back: (project(left, space.near), project(right, space.near)),
        front: (
          Offset.lerp(wall.$1, project(left, space.far), ratio)!,
          Offset.lerp(wall.$2, project(right, space.far), ratio)!,
        ),
        perspective: space,
      );
    }
    if (flat == null) return null;
    final center = Offset(flat.x(lane), flat.judgement);
    final half = (flat.span * .094).clamp(3.0, 30.0);
    final left = flat.x(lane - halfLane), right = flat.x(lane + halfLane);
    final top = math.max(0.0, center.dy - half * 6);
    return ChartHitFrame._(
      center: center,
      radius: half,
      ovalAxisStart: center,
      ovalAxisEnd: center,
      endRadius: half,
      wall: (Offset(left, center.dy), Offset(right, center.dy)),
      back: (Offset(left, flat.size.height), Offset(right, flat.size.height)),
      front: (Offset(left, top), Offset(right, top)),
    );
  }

  static ChartHitFrame? air(
    ({double x, double height}) aim, {
    required bool skyTap,
    ({double x, double height})? tip,
    AffGroupOptions? angles,
    PerspectiveGeometry? space,
    TimelineGeometry? flat,
  }) {
    if (space == null && flat == null) return null;
    final end = tip ?? aim;
    Offset project(double x, double height, double? depth) {
      if (space == null) {
        return Offset(flat!.x(x, airborne: true), flat.judgement);
      }
      final at = depth ?? space.time;
      final point = skyTap
          ? space.projectArcTap(x, height, at, angles: angles)
          : space.projectAir(x, height, at, angles: angles);
      return space.baseHorizontal(point);
    }

    double reach(double x, double h) {
      if (space == null) {
        return math.max(22.0, flat!.arcTapBounds(x, h, flat.ms).width * .75);
      }
      const half = PerspectiveGeometry.arcTapHalfWidth;
      final left = space.baseHorizontal(
        space.projectArcTap(x - half, h, space.time, angles: angles),
      );
      final right = space.baseHorizontal(
        space.projectArcTap(x + half, h, space.time, angles: angles),
      );
      return math.max(22.0, (right - left).distance * .75);
    }

    final a = project(aim.x, aim.height, null),
        b = project(end.x, end.height, null);
    final ra = reach(aim.x, aim.height), rb = reach(end.x, end.height);
    final center = (a + b) / 2;
    final radius = ra + (a - b).distance / 2;
    final wall = (center.translate(-radius, 0), center.translate(radius, 0));
    var front = center.translate(0, -ra * 2),
        back = center.translate(0, ra * 2);
    if (space != null) {
      final heading = project(aim.x, aim.height, space.near) - a;
      final direction = heading.distance < .001
          ? const Offset(0, 1)
          : heading / heading.distance;
      front = center - direction * ra * 2;
      back = center + direction * ra * 2;
    }
    return ChartHitFrame._(
      center: center,
      radius: radius,
      ovalAxisStart: a,
      ovalAxisEnd: b,
      endRadius: rb,
      wall: wall,
      back: (back.translate(-radius, 0), back.translate(radius, 0)),
      front: (front.translate(-radius, 0), front.translate(radius, 0)),
      perspective: space,
    );
  }

  List<Offset> _lane(ChartHitArea area) {
    (Offset, Offset) limit((Offset, Offset) end, double distance) {
      final left = Offset.lerp(wall.$1, end.$1, distance)!;
      final right = Offset.lerp(wall.$2, end.$2, distance)!;
      final middle = (left + right) / 2;
      final span = (right - left) / 2;
      // A steep extension may pass the vanishing point. Keep the lane polygon
      // ordered so its sides do not cross.
      final half = span.dx * laneAcross.dx + span.dy * laneAcross.dy < 0
          ? laneAcross
          : span;
      return (middle - half * area.width, middle + half * area.width);
    }

    final top = limit(front, area.forward);
    final bottom = limit(back, area.backward);
    return [top.$1, top.$2, bottom.$2, bottom.$1];
  }

  Offset _ovalPoint(double angle, ChartHitArea area) {
    final x = math.cos(angle), y = math.sin(angle);
    final startRadius = radius - (ovalAxisEnd - ovalAxisStart).distance / 2;
    final a =
        ovalAxisStart +
        Offset(
          startRadius * area.width * x,
          startRadius * area.height * 1.10 * y,
        );
    final b =
        ovalAxisEnd +
        Offset(endRadius * area.width * x, endRadius * area.height * 1.10 * y);
    return (a.dx - b.dx) * x / area.width +
                (a.dy - b.dy) * y / (area.height * 1.1) >=
            0
        ? a
        : b;
  }

  List<Offset> _outline(ChartHitArea area) => switch (area.shape) {
    ChartHitShape.oval => [
      for (var i = 0; i < 64; i++) _ovalPoint(i * math.pi / 32, area),
    ],
    ChartHitShape.lane => _lane(area),
    ChartHitShape.quadrilateral => [
      for (final p in area.vertices) center + p * radius,
    ],
    ChartHitShape.square || ChartHitShape.rectangle => [
      for (final p in const [
        Offset(-1, -1),
        Offset(1, -1),
        Offset(1, 1),
        Offset(-1, 1),
      ])
        center +
            Offset(
              p.dx * radius * area.width,
              p.dy *
                  radius *
                  (area.shape == ChartHitShape.square
                      ? area.width
                      : area.height),
            ),
    ],
  };

  List<Offset> outline(ChartHitArea area) =>
      _outline(area).map(toScreen).toList();
  List<Offset> handles(ChartHitArea area) => area.shape == ChartHitShape.oval
      ? [
          for (var i = 0; i < 4; i++)
            toScreen(_ovalPoint(i * math.pi / 2, area)),
        ]
      : outline(area);

  double? distance(ChartHitArea area, Offset screen) {
    final point = fromScreen(screen);
    if (area.shape == ChartHitShape.oval) {
      final axis = ovalAxisEnd - ovalAxisStart;
      final from = point - ovalAxisStart;
      final normalizedAxis = Offset(
        axis.dx / area.width,
        axis.dy / (area.height * 1.10),
      );
      final normalized = Offset(
        from.dx / area.width,
        from.dy / (area.height * 1.10),
      );
      final startRadius = radius - axis.distance / 2;
      final change = endRadius - startRadius;
      final quadratic = normalizedAxis.distanceSquared - change * change;
      final projection =
          normalized.dx * normalizedAxis.dx +
          normalized.dy * normalizedAxis.dy +
          startRadius * change;
      final fraction = quadratic > 1e-6
          ? (projection / quadratic).clamp(0.0, 1.0)
          : (quadratic - 2 * projection < 0 ? 1.0 : 0.0);
      final reach = startRadius + change * fraction;
      final ratio =
          (normalized - normalizedAxis * fraction).distanceSquared /
          (reach * reach);
      return ratio <= 1 ? ratio : null;
    }
    final points = _outline(area);
    if (!_insidePolygon(points, point)) return null;
    final offset = point - center;
    if (area.shape == ChartHitShape.lane) {
      final across = offset.dx * laneAcross.dx + offset.dy * laneAcross.dy;
      final ahead = offset.dx * laneForward.dx + offset.dy * laneForward.dy;
      return math.pow(across / laneHalfWidth, 2).toDouble() +
          math.pow(ahead / forwardLength, 2).toDouble() * .15;
    }
    return offset.distanceSquared / (radius * radius);
  }
}

bool _insidePolygon(List<Offset> points, Offset point) {
  var inside = false;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    final edge = b - a, d = point - a;
    if (edge.distanceSquared > 1e-8 &&
        (edge.dx * d.dy - edge.dy * d.dx).abs() < 1e-5 &&
        (point - a).distanceSquared + (point - b).distanceSquared <=
            edge.distanceSquared + 1e-5) {
      return true;
    }
    if ((a.dy > point.dy) != (b.dy > point.dy) &&
        point.dx < a.dx + (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy)) {
      inside = !inside;
    }
  }
  return inside;
}
