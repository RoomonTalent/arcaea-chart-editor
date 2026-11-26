import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_editor_visibility.dart';
import 'chart_practice_segment.dart';
import 'chart_playback_view.dart';
import 'chart_scene.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';

/// Projects chart time along depth and preserves AFF height above the track.
class PerspectiveGeometry {
  PerspectiveGeometry(
    this.size,
    this.time,
    this.lookahead, {
    this.camera,
    this.widen = 0,
    this.playbackLanes,
    this.playbackView = defaultChartPlaybackView,
  });

  factory PerspectiveGeometry.forScene(
    Size size,
    double time,
    double lookahead,
    ChartScene scene, {
    bool editing = false,
  }) {
    final pose = editing ? defaultCamera : scene.camera(time);
    return PerspectiveGeometry(
      size,
      time,
      lookahead,
      camera: pose == defaultCamera ? null : CameraProjection(pose),
      widen: scene.widenCamera(time),
    );
  }

  factory PerspectiveGeometry.forPlayback(
    Size size,
    double time,
    double lookahead,
    ChartTimeline timeline,
    ChartLaneMode lanes, {
    ChartPlaybackView view = defaultChartPlaybackView,
    double? sceneTime,
  }) {
    final scene = timeline.scene;
    final current = sceneTime ?? time;
    final pose = scene.camera(current);
    return PerspectiveGeometry(
      size,
      time,
      lookahead,
      camera: pose == defaultCamera ? null : CameraProjection(pose),
      widen: scene.widenCamera(current),
      playbackLanes: lanes.expansion(timeline, current),
      playbackView: view,
    );
  }

  final Size size;
  final double time, lookahead;
  final CameraProjection? camera;
  final double widen;
  final double? playbackLanes;
  final ChartPlaybackView playbackView;
  late final _wide = size.width / size.height >= 5 / 3;
  late final _defaultPitch = (_wide ? 26.565 : 27.378) * math.pi / 180;
  late final _pitch =
      _defaultPitch + playbackView.pitch.remainder(360) * math.pi / 180;
  late final _pitchCos = math.cos(_pitch);
  late final _pitchSin = math.sin(_pitch);
  late final _defaultCos = math.cos(_defaultPitch);
  late final _defaultSin = math.sin(_defaultPitch);
  // Guard floating-point projection and inverse projection at degenerate sizes.
  late final _widthScale = playbackView.width.abs().clamp(1e-4, 1e4);
  late final _lengthScale = playbackView.length.abs().clamp(1e-4, 1e4);
  late final _cameraHeight = 12.75 + 4.5 * widen;
  late final double _baseDistance = _wide ? 15 : 14;
  late final _cameraDistance = _baseDistance + (_wide ? 4.5 : 4) * widen;
  late final _baseFocal = math.min(
    size.height * 0.5 / math.tan((_wide ? 25 : 32.5) * math.pi / 180),
    size.width *
        0.42 *
        (_baseDistance * _defaultCos + 12.75 * _defaultSin) /
        (_trackWidth * 0.75),
  );
  // AFF sky x=0..1 spans two of the four ground lanes.
  static const _trackWidth = 17.0;
  static const _skyWidth = 8.5;
  static const arcTapHalfWidth = 4.4625 / _skyWidth / 2;
  static const flickHalfWidth = 0.10;
  static const _defaultDepthSpan = 68.0;
  late final _depthSpan = _defaultDepthSpan * _lengthScale;
  static const _airHeight = 4.5;
  static const _airFloor = 1 / _airHeight;
  static const _arcTapDepth = 1.2;
  static const _arcTapHeight = 0.6;
  static const nearCameraDepth = 1.5;
  late final _nearForward = _cameraDistance - _defaultDepthSpan * 0.06;
  late final _runout = playbackView.runout.abs().clamp(0.0, 1000.0);
  late final _runoutForward =
      _cameraDistance - _defaultDepthSpan * .06 * _runout;
  late final _nearDepth =
      _cameraHeight * _defaultSin + _nearForward * _defaultCos;
  late final _focal = playbackLanes == null
      ? _baseFocal
      : math.min(
          _baseFocal * 1.10,
          size.width *
              .99 *
              _nearDepth /
              (_trackWidth * (1 + .5 * playbackLanes!)),
        );
  late final _baseOrigin = Offset(
    size.width / 2,
    playbackLanes == null
        ? size.height / 2
        : size.height -
              (_cameraHeight * _defaultCos - _runoutForward * _defaultSin) *
                  _focal /
                  math.max(
                    .7,
                    _cameraHeight * _defaultSin + _runoutForward * _defaultCos,
                  ),
  );
  late final _origin = _baseOrigin.translate(
    0,
    _groundWallOffset(_defaultCos, _defaultSin) -
        _groundWallOffset(_pitchCos, _pitchSin) -
        playbackView.height.clamp(-1e6, 1e6) / 100 * size.height,
  );

  // Tilt around the judgement line. The height control can move that line
  // independently without losing the ground input when using a shallow angle.
  double _groundWallOffset(double cosine, double sine) =>
      (_cameraHeight * cosine - _cameraDistance * sine) *
      _focal /
      math.max(.7, _cameraHeight * sine + _cameraDistance * cosine);
  double get skyLineHeight => 1 + widen * .61;
  late final _skyHeightScale =
      _playbackSkyScale() * playbackView.skyHeight.abs().clamp(1e-4, 1e3);

  double _playbackSkyScale() {
    if (playbackLanes == null) return 1;
    // Frame the height-one sky input near mid-screen independently of the
    // focal length, which also has to keep the ground lanes inside the view.
    final phoneRatio = ((size.width / size.height - 1.45) / .7).clamp(0.0, 1.0);
    final skyFraction = .45 - .045 * phoneRatio;
    final screen = (size.height * skyFraction - _baseOrigin.dy) / _focal;
    final down = _defaultSin + screen * _defaultCos;
    final forward = _defaultCos - screen * _defaultSin;
    final skyWorldHeight = _cameraHeight - _cameraDistance * down / forward;
    return ((skyWorldHeight / _airHeight - _airFloor) / skyLineHeight).clamp(
      1.0,
      4.5,
    );
  }

  static ({double start, double end})? _clipNear(
    double start,
    double end,
    double Function(double) depth,
  ) {
    bool inFront(double at) => depth(at) >= nearCameraDepth;
    final front = inFront(start), back = inFront(end);
    if (!front && !back) return null;
    if (front != back) {
      var visible = front ? start : end;
      var hidden = front ? end : start;
      for (var i = 0; i < 12; i++) {
        final mid = (visible + hidden) / 2;
        if (inFront(mid)) {
          visible = mid;
        } else {
          hidden = mid;
        }
      }
      if (front) {
        end = visible;
      } else {
        start = visible;
      }
    }
    return (start: start, end: end);
  }

  double wallHeight({bool arcTap = false}) {
    final c = _pitchCos, s = _pitchSin;
    final screen = (size.height * .04 - _origin.dy) / _focal;
    final down = s + screen * c, forward = c - screen * s;
    final wallDistance = _cameraDistance + (arcTap ? _arcTapDepth / 2 : 0);
    final heightOffset = arcTap ? 0.5 : 0.0;
    return (((_cameraHeight - wallDistance * down / forward + heightOffset) /
                    _airHeight -
                _airFloor) /
            _skyHeightScale)
        .clamp(skyLineHeight, math.max(2.5, skyLineHeight));
  }

  late final width = (project(1, 0, time) - project(0, 0, time)).distance;
  double get far => time + lookahead;
  double get near => time - lookahead * 0.06 * _runout / _lengthScale;
  double noteDepth(double msAtNormalSpeed) =>
      msAtNormalSpeed * lookahead / 2100;
  double get judgementTolerance => noteDepth(2);

  double arcTapDistance(
    Offset position,
    double x,
    double height, {
    AffGroupOptions? angles,
  }) {
    final left = projectArcTap(
      x - arcTapHalfWidth,
      height,
      time,
      angles: angles,
    );
    final right = projectArcTap(
      x + arcTapHalfWidth,
      height,
      time,
      angles: angles,
    );
    final axis = right - left;
    if (axis.distanceSquared < 1e-6) return (position - left).distance;
    final relative = position - left;
    final fraction =
        ((relative.dx * axis.dx + relative.dy * axis.dy) / axis.distanceSquared)
            .clamp(0.0, 1.0);
    return (relative - axis * fraction).distance;
  }

  Offset flickDirection(
    double x,
    double height,
    double at,
    Offset direction, {
    AffGroupOptions? angles,
  }) {
    final magnitude = math.max(direction.dx.abs(), direction.dy.abs());
    if (magnitude == 0) return Offset.zero;
    // Project a local direction. AFF vector length must not move the key
    // or move the sample point through the perspective near plane.
    final unit = direction / magnitude * 0.01;
    final before = projectAir(
      x - unit.dx,
      height - unit.dy,
      at,
      angles: angles,
    );
    final after = projectAir(x + unit.dx, height + unit.dy, at, angles: angles);
    return after - before;
  }

  double flickArrowLength(
    double x,
    double height,
    double at, {
    AffGroupOptions? angles,
  }) {
    final left = projectAir(x - flickHalfWidth, height, at, angles: angles);
    final right = projectAir(x + flickHalfWidth, height, at, angles: angles);
    return ((right - left).distance * 0.65).clamp(3.0, 20.0);
  }

  ({double x, double height, double at}) _airPosition(
    double x,
    double height,
    double at,
    AffGroupOptions? angles,
  ) {
    final laneX = 0.5 + (x - 0.5) * (_skyWidth / _trackWidth);
    final airY = _airFloor + height * _skyHeightScale;
    if (angles == null || (angles.angleX == 0 && angles.angleY == 0)) {
      return (x: laneX, height: airY, at: at);
    }
    final pitch = angles.angleX * math.pi / 180;
    final yaw = angles.angleY * math.pi / 180;
    final distance = (at - time) / lookahead * _depthSpan;
    return (
      x: laneX - math.sin(yaw) * math.cos(pitch) * distance / _trackWidth,
      height: airY + math.sin(pitch) * distance / _airHeight,
      at: time + (at - time) * math.cos(pitch) * math.cos(yaw),
    );
  }

  Offset projectAir(
    double x,
    double height,
    double at, {
    AffGroupOptions? angles,
  }) {
    final point = _airPosition(x, height, at, angles);
    return project(point.x, point.height, point.at);
  }

  Offset projectArcTap(
    double x,
    double height,
    double at, {
    AffGroupOptions? angles,
    double modelHeight = 0,
    double modelDepth = 0,
  }) {
    final point = _arcTapPosition(
      x,
      height,
      at,
      angles,
      modelHeight,
      modelDepth,
    );
    return project(point.x, point.height, point.at);
  }

  ({double x, double height, double at}) _arcTapPosition(
    double x,
    double height,
    double at,
    AffGroupOptions? angles,
    double modelHeight,
    double modelDepth,
  ) {
    final point = _airPosition(x, height, at, angles);
    return (
      x: point.x,
      height: point.height + (modelHeight - 0.5) / _airHeight,
      at: point.at + (_arcTapDepth / 2 + modelDepth) / _depthSpan * lookahead,
    );
  }

  double viewDepth(
    double x,
    double height,
    double at, {
    bool air = false,
    AffGroupOptions? angles,
  }) {
    final point = air
        ? _airPosition(x, height, at, angles)
        : (x: x, height: height, at: at);
    final u = (point.x.clamp(-3.0, 4.0) - 0.5) * _trackWidth;
    final vertical = _cameraHeight - point.height.clamp(-2.0, 5.0) * _airHeight;
    final forward =
        _cameraDistance + (point.at - time) / lookahead * _depthSpan;
    return camera?.viewDepth(_pitch, u, vertical, forward) ??
        vertical * _pitchSin + forward * _pitchCos;
  }

  Offset project(double x, double height, double at) {
    final u = (x.clamp(-3.0, 4.0) - 0.5) * _trackWidth;
    final vertical = _cameraHeight - height.clamp(-2.0, 5.0) * _airHeight;
    final forward = _cameraDistance + (at - time) / lookahead * _depthSpan;
    if (camera case final transform?) {
      final point = transform.project(
        _origin,
        _focal,
        _pitch,
        u,
        vertical,
        forward,
      );
      return Offset(
        _origin.dx + (point.dx - _origin.dx) * _widthScale,
        point.dy,
      );
    }
    final c = _pitchCos, s = _pitchSin;
    final zoom = _focal / math.max(0.7, vertical * s + forward * c);
    return _origin +
        Offset(u * zoom * _widthScale, (vertical * c - forward * s) * zoom);
  }

  Offset baseHorizontal(Offset point) =>
      Offset(_origin.dx + (point.dx - _origin.dx) / _widthScale, point.dy);
  Offset stretchHorizontal(Offset point) =>
      Offset(_origin.dx + (point.dx - _origin.dx) * _widthScale, point.dy);
  double get horizontalScale => _widthScale;

  /// Intersects a pointer ray with the judgement wall or the ground plane.
  ({double x, double height, double depth})? pick(
    Offset point, {
    required bool air,
    bool arcTap = false,
    bool allowOverflow = true,
  }) {
    final c = _pitchCos, s = _pitchSin;
    final screenX = (baseHorizontal(point).dx - _origin.dx) / _focal;
    final screenY = (point.dy - _origin.dy) / _focal;
    final down = s + screenY * c;
    final forward = c - screenY * s;
    final denominator = air ? forward : down;
    if (denominator <= 0.01) return null;
    final keyWall = air && arcTap;
    final wallDistance = _cameraDistance + (keyWall ? _arcTapDepth / 2 : 0);
    final scale = (air ? wallDistance : _cameraHeight) / denominator;
    final depth = air
        ? time
        : time + (scale * forward - _cameraDistance) / _depthSpan * lookahead;
    final heightOffset = keyWall ? 0.5 : 0.0;
    return (
      x: (0.5 + screenX * scale / (air ? _skyWidth : _trackWidth)).clamp(
        !air && allowOverflow ? AffChart.minGroundX : -0.5,
        !air && allowOverflow ? AffChart.maxGroundX : 1.5,
      ),
      height:
          (((_cameraHeight - down * scale + heightOffset) / _airHeight -
                      _airFloor) /
                  _skyHeightScale)
              .clamp(
                0.0,
                allowOverflow ? wallHeight(arcTap: keyWall) : skyLineHeight,
              ),
      depth: depth,
    );
  }

  /// Inverts the editing projection at an authored point's scroll depth.
  ({double x, double height})? pickAirAt(
    Offset point,
    double at, {
    required bool arcTap,
    AffGroupOptions? angles,
  }) {
    final origin = arcTap
        ? _arcTapPosition(0.5, 0, at, angles, 0, 0)
        : _airPosition(0.5, 0, at, angles);
    final screenX = (baseHorizontal(point).dx - _origin.dx) / _focal;
    final screenY = (point.dy - _origin.dy) / _focal;
    final c = _pitchCos, s = _pitchSin;
    final forward = c - screenY * s;
    if (forward <= 0.01) return null;
    final depth = _cameraDistance + (origin.at - time) / lookahead * _depthSpan;
    final scale = depth / forward;
    if (scale <= 0.7) return null;
    final height = (_cameraHeight - (s + screenY * c) * scale) / _airHeight;
    return (
      x: 0.5 + (screenX * scale - (origin.x - 0.5) * _trackWidth) / _skyWidth,
      height: (height - origin.height) / _skyHeightScale,
    );
  }
}

class CameraProjection {
  CameraProjection(this.pose);

  final CameraPose pose;
  static const _rad = math.pi / 180;
  late final _yawCos = math.cos(pose.yaw * _rad);
  late final _yawSin = math.sin(pose.yaw * _rad);
  late final _rollCos = math.cos(pose.roll * _rad);
  late final _rollSin = math.sin(pose.roll * _rad);

  double viewDepth(double pitch, double u, double v, double depth) {
    final angle = pitch + pose.pitch * _rad;
    final forward =
        (u - pose.x / 1000) * _yawSin + (depth + pose.z / 1000) * _yawCos;
    return (v + pose.y / 1000) * math.sin(angle) + forward * math.cos(angle);
  }

  Offset project(
    Offset origin,
    double focal,
    double pitch,
    double u,
    double v,
    double depth,
  ) {
    final pitchCos = math.cos(pitch + pose.pitch * _rad);
    final pitchSin = math.sin(pitch + pose.pitch * _rad);
    final x = u - pose.x / 1000;
    final y = v + pose.y / 1000;
    final z = depth + pose.z / 1000;
    final horizontal = x * _yawCos - z * _yawSin;
    final forward = x * _yawSin + z * _yawCos;
    final vertical = y * pitchCos - forward * pitchSin;
    final zoom = focal / math.max(0.7, y * pitchSin + forward * pitchCos);
    return origin +
        Offset(
          (horizontal * _rollCos - vertical * _rollSin) * zoom,
          (horizontal * _rollSin + vertical * _rollCos) * zoom,
        );
  }
}

typedef PerspectiveKeyframeMarker = ({
  Offset point,
  bool tap,
  Rect? outline,
  bool detached,
});

class ChartPerspectivePainter extends CustomPainter {
  ChartPerspectivePainter(
    this.timeline,
    this.position,
    this.lookahead, {
    this.skin = ChartSkin.defaults,
    this.editing = false,
    this.wall = false,
    this.arcTapWall = false,
    this.visibility,
    this.handles = const [],
    this.keyframes,
    this.snapPoint,
    this.activeGroup = 0,
    this.laneMode = ChartLaneMode.automatic,
    this.judgement,
    this.appearance = defaultChartAppearance,
    this.playbackFraming = false,
    this.noteOpacity = 1,
    this.reverse = false,
    this.frozenAt,
    this.practiceSegment,
    this.playbackView = defaultChartPlaybackView,
  }) : super(repaint: position);

  final ChartTimeline timeline;
  final ValueNotifier<double> position;
  final double lookahead;
  final double? frozenAt;
  final ChartPracticeSegment? practiceSegment;
  final bool reverse;
  final ChartPlaybackView playbackView;
  final ChartSkin skin;
  final bool editing, wall, arcTapWall;
  final bool playbackFraming;
  final double noteOpacity;
  final ChartEditorVisibility? visibility;
  final List<({int time, double x, double height})> handles;
  final Iterable<PerspectiveKeyframeMarker> Function(PerspectiveGeometry)?
  keyframes;
  final Offset? snapPoint;
  final int activeGroup;
  final ChartLaneMode laneMode;
  final ChartAppearance appearance;
  final ChartJudgement? judgement;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final clock = position.value;
    final time = frozenAt ?? clock;
    final scene = timeline.scene;
    final g = playbackFraming
        ? PerspectiveGeometry.forPlayback(
            size,
            time,
            lookahead,
            timeline,
            laneMode,
            view: playbackView,
            sceneTime: clock,
          )
        : PerspectiveGeometry.forScene(
            size,
            time,
            lookahead,
            scene,
            editing: editing,
          );
    final paint = Paint()..isAntiAlias = true;
    final direction = reverse ? -1 : 1;
    final nearDelta = g.near - time;
    final farDelta = g.far - time;
    final low = reverse ? -farDelta : nearDelta;
    final high = reverse ? -nearDelta : farDelta;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final distortion = scene.distortion(clock);
    canvas.save();
    if (distortion > 0) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(1 + distortion * 0.08);
      canvas.skew(math.sin(clock / 120) * distortion * 0.07, 0);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    skin.paintBackground(canvas, size, flat: false);
    canvas.restore();

    void line(Offset a, Offset b, Color color, [double width = 1]) {
      canvas.drawLine(
        a,
        b,
        paint
          ..color = color
          ..strokeWidth = width,
      );
    }

    void strip(List<Offset> corners, Color color) {
      canvas.drawPath(Path()..addPolygon(corners, true), paint..color = color);
    }

    void mark(Offset point) {
      canvas.drawCircle(point, 7, paint..color = const Color(0xFFFFD670));
      canvas.drawCircle(point, 3.5, paint..color = const Color(0xFF132338));
    }

    final trackOpacity = scene.track(clock);
    final widening = laneMode.expansion(timeline, clock, editing: editing);
    final leftLane = -0.25 * widening;
    final rightLane = 1 + 0.25 * widening;
    void trackSurface(double left, double right, ChartTexture? texture) {
      if (texture == null) {
        strip([
          g.project(left, 0, g.near),
          g.project(right, 0, g.near),
          g.project(right, 0, g.far),
          g.project(left, 0, g.far),
        ], const Color(0xFF25324D).withValues(alpha: trackOpacity));
        return;
      }
      final vertices = <Offset>[];
      for (var row = 0; row <= 28; row++) {
        final at = g.near + (g.far - g.near) * row / 28;
        vertices.addAll([g.project(left, 0, at), g.project(right, 0, at)]);
      }
      final start =
          ((direction * timeline.scroll(0).at(time) + nearDelta) / 360) % 1;
      texture.strip(
        canvas,
        vertices,
        start: start,
        end: start + (g.far - g.near) / 360,
        alpha: trackOpacity,
      );
    }

    trackSurface(0, 1, skin[ChartSprite.track]);
    if (widening > 0) {
      final extra = skin[ChartSprite.extraTrack];
      trackSurface(leftLane, 0, extra);
      trackSurface(1, rightLane, extra);
    }
    for (final x in {leftLane, 0.0, 0.25, 0.5, 0.75, 1.0, rightLane}) {
      final edge = x == leftLane || x == rightLane;
      line(
        g.project(x, 0, g.near),
        g.project(x, 0, g.far),
        (edge ? const Color(0xFFA6B9DF) : const Color(0x996E7DA0)).withValues(
          alpha: trackOpacity * (edge ? 1 : 0.6),
        ),
      );
    }
    final mainScroll = timeline.scroll(0);
    final cursor = mainScroll.at(time);
    for (final range in mainScroll.visible(
      cursor + low,
      cursor + high,
      time - (reverse ? 30000 : 125),
      time + (reverse ? 125 : 30000),
    )) {
      for (final beat in timeline.beats(range.start, range.end)) {
        final depth = time + direction * (mainScroll.at(beat.time) - cursor);
        line(
          g.project(leftLane, 0, depth),
          g.project(rightLane, 0, depth),
          (beat.downbeat ? const Color(0xAA92AAD0) : const Color(0x6662759A))
              .withValues(alpha: trackOpacity * (beat.downbeat ? 0.67 : 0.4)),
        );
      }
    }
    final skyHeight = g.skyLineHeight;
    final skyStart = g.projectAir(2 * leftLane - 0.5, skyHeight, g.time);
    final skyEnd = g.projectAir(2 * rightLane - 0.5, skyHeight, g.time);
    final intersections = <({Offset point, double opacity})>[];
    final highlights = <({Offset left, Offset right})>[];
    final selectionMarks = <Offset>[];
    final stacks = ChartStackLabels();
    final bodies =
        <({AffEvent note, double start, double end, double depth, int? tap})>[];
    final distinctTaps = <({AffEvent note, int tap})>{};
    final visibleSingles = <AffEvent>{};
    final segment = practiceSegment;
    for (final (:note, start: visibleStart, end: visibleEnd)
        in timeline.visibleInPerspective(
          time,
          low,
          high,
          history: reverse ? double.infinity : 500,
        )) {
      if (!laneMode.showsAt(timeline, note, clock) ||
          (segment != null && !segment.shows(note))) {
        continue;
      }
      final start = math.max(
        visibleStart,
        segment?.start ?? double.negativeInfinity,
      );
      final end = math.min(visibleEnd, segment?.end ?? double.infinity);
      if (end < start) continue;
      final bodyHidden =
          (segment != null && !segment.showsBody(note)) ||
          visibility?.shows(note) == false ||
          judgement?.hidden(note, clock) == true;
      if (bodyHidden && note.arcTaps.isEmpty) continue;
      if (!editing && scene.groupOpacity(note.group, clock) == 0) continue;
      final scroll = timeline.scroll(note.group);
      final atCursor = scroll.at(time);
      double depth(double at) => direction * (scroll.at(at) - atCursor);
      void piece(double from, double to, {int? tap}) {
        double viewDepth(double at) {
          final point = note.isAir
              ? note.point(at)
              : (x: note.laneX, height: 0.0);
          return g.viewDepth(
            point.x,
            point.height,
            time + depth(at),
            air: note.isAir,
            angles: timeline.groupOptions[note.group],
          );
        }

        final instantArc =
            tap == null && note.kind == AffKind.arc && note.start == note.end;
        if (note.isAir && !instantArc) {
          final clipped = PerspectiveGeometry._clipNear(from, to, viewDepth);
          if (clipped == null) return;
          from = clipped.start;
          to = clipped.end;
        }
        bodies.add((
          note: note,
          start: from,
          end: to,
          tap: tap,
          depth: viewDepth((from + to) / 2),
        ));
      }

      if (!bodyHidden &&
          (note.kind == AffKind.arc || note.kind == AffKind.hold)) {
        final spans = judgement != null
            ? judgement!.visibleSustain(note, start, end)
            : [(start: start, end: end)];
        for (final span in spans) {
          final extend =
              note.kind == AffKind.hold &&
              span.start == note.start &&
              clock < note.start &&
              time < span.start &&
              judgement?.earlyHolds.contains(note) == true;
          final start = extend ? time : span.start;
          final splits = [start, ...scroll.breaks(start, span.end), span.end];
          for (var i = 1; i < splits.length; i++) {
            final from = splits[i - 1], to = splits[i];
            final count =
                ((depth(to) - depth(from)).abs() /
                        g.noteDepth(editing ? 100 : 300))
                    .ceil()
                    .clamp(1, 32);
            for (var part = 0; part < count; part++) {
              piece(
                from + (to - from) * part / count,
                from + (to - from) * (part + 1) / count,
              );
            }
          }
        }
      } else if (!bodyHidden) {
        piece(start, end);
      }
      if (note.start == note.end) visibleSingles.add(note);
      for (final tap in note.arcTaps) {
        if ((segment != null && !segment.includes(tap)) ||
            visibility?.shows(note, tap: tap) == false ||
            tap < start - 1e-5 ||
            tap > end + 1e-5 ||
            judgement?.hidden(note, clock, tap: tap) == true ||
            !distinctTaps.add((note: note, tap: tap))) {
          continue;
        }
        piece(tap.toDouble(), tap.toDouble(), tap: tap);
      }

      if (!bodyHidden && note.kind == AffKind.arc && note.start != note.end) {
        for (final cross in scroll.visible(atCursor, atCursor, start, end)) {
          final at = time.clamp(cross.start, cross.end);
          if (judgement?.consumedAt(note, at) == true) continue;
          final point = note.point(at);
          final opacity =
              noteOpacity *
              (note.trace
                  ? appearance.trace * chartTraceOpacity
                  : appearance.snake);
          if (opacity == 0) continue;
          intersections.add((
            point: g.projectAir(
              point.x,
              point.height,
              time,
              angles: timeline.groupOptions[note.group],
            ),
            opacity: opacity,
          ));
        }
      }
    }
    if (judgement != null && !reverse && frozenAt == null) {
      // Leave a short, visible runout for missed keys even at high scroll speed.
      for (final note in timeline.visible(time - 360, time)) {
        if (!laneMode.showsAt(timeline, note, time) ||
            note.noInput ||
            scene.groupOpacity(note.group, time) == 0) {
          continue;
        }
        final scroll = timeline.scroll(note.group);
        void retain(int at, {int? tap}) {
          if ((segment != null && !segment.includes(at)) ||
              visibility?.shows(note, tap: tap) == false ||
              time - at > 360 ||
              time - at < 0 ||
              judgement!.hidden(note, time, tap: tap) ||
              scroll.at(at.toDouble()) - scroll.at(time) >= g.near - time) {
            return;
          }
          final point = note.isAir
              ? note.point(at.toDouble())
              : (x: note.laneX, height: 0.0);
          bodies.add((
            note: note,
            start: at.toDouble(),
            end: at.toDouble(),
            tap: tap,
            depth: g.viewDepth(
              point.x,
              point.height,
              g.near,
              air: note.isAir,
              angles: timeline.groupOptions[note.group],
            ),
          ));
        }

        if ((note.kind == AffKind.tap ||
                note.kind == AffKind.flick ||
                note.variableArcTap) &&
            !visibleSingles.contains(note)) {
          retain(note.start);
        }
        for (final tap in note.arcTaps) {
          if (distinctTaps.add((note: note, tap: tap))) retain(tap, tap: tap);
        }
      }
    }
    if (appearance.trace > 0) {
      final chords = <int, List<ChartChordPoint>>{};
      final anchors = <(AffEvent, int?)>{};
      for (final (:note, :tap, depth: viewDepth, start: _, end: _) in bodies) {
        if (note.noInput ||
            note.designant ||
            (tap == null && !note.variableArcTap && note.kind != AffKind.tap) ||
            (note.isAir && appearance.arcTap == 0) ||
            viewDepth < PerspectiveGeometry.nearCameraDepth ||
            !anchors.add((note, tap))) {
          continue;
        }
        final at = tap ?? note.start;
        final scroll = timeline.scroll(note.group);
        final depth =
            time + direction * (scroll.at(at.toDouble()) - scroll.at(time));
        if (depth < g.near || depth > g.far || (!reverse && at < time - 16)) {
          continue;
        }
        final Offset point;
        if (note.isAir) {
          final first = note.point(at.toDouble());
          final angles = timeline.groupOptions[note.group];
          final head = g.projectArcTap(
            first.x,
            first.height,
            depth,
            angles: angles,
          );
          final tail = note.variableArcTap ? note.arcPoint(1) : null;
          point = tail == null
              ? head
              : (head +
                        g.projectArcTap(
                          tail.x,
                          tail.height,
                          depth,
                          angles: angles,
                        )) /
                    2;
        } else {
          point = g.project(note.laneX, .038, depth);
        }
        final opacity =
            noteOpacity *
            (editing ? 1.0 : scene.groupOpacity(note.group, clock));
        (chords[at] ??= []).add((
          point: point,
          air: note.isAir,
          opacity: opacity,
          depth: depth,
        ));
      }
      paintChartChords(
        canvas,
        chords.values,
        appearance.trace,
        depthTolerance: g.noteDepth(40),
      );
    }
    bodies.sort((a, b) {
      final depth = b.depth.compareTo(a.depth);
      if (depth != 0) return depth;
      final tapOrder = (a.tap == null ? 0 : 1).compareTo(b.tap == null ? 0 : 1);
      return tapOrder == 0
          ? a.note.sourceStart.compareTo(b.note.sourceStart)
          : tapOrder;
    });
    for (final (:note, :start, :end, :tap, depth: _) in bodies) {
      final opacity =
          noteOpacity * (editing ? 1.0 : scene.groupOpacity(note.group, clock));
      if (opacity == 0) continue;
      final scroll = timeline.scroll(note.group);
      final atCursor = scroll.at(time);
      double depthAt(double at) =>
          (time + direction * (scroll.at(at) - atCursor)).clamp(g.near, g.far);
      final options = timeline.groupOptions[note.group];
      final alpha =
          opacity *
          (note.noInput
              ? 0.30
              : note.end < g.time - 40
              ? 0.45
              : 0.95);
      if (note.kind == AffKind.arc) {
        Offset air(double x, double height, double depth) =>
            g.projectAir(x, height, depth, angles: options);
        final selected = visibility?.selected(note, tap: tap) == true;
        final tint = selected
            ? Colors.white
            : ChartTimelinePainter.arcColor(note);
        final noteOpacity = tap != null || note.variableArcTap
            ? appearance.arcTap
            : note.trace
            ? appearance.trace * chartTraceOpacity
            : appearance.snake;
        final guide =
            editing && tap == null && visibility?.showsGuide(note) == true;
        if (noteOpacity == 0 && !guide) continue;
        final color = tint.withValues(alpha: alpha * noteOpacity);
        if (tap != null) {
          final point = note.point(tap.toDouble());
          stacks.add(
            note,
            g.projectArcTap(
              point.x,
              point.height,
              depthAt(start),
              angles: options,
            ),
            tap: tap,
            count:
                judgement?.remainingTaps(note, tap, clock) ??
                note.arcTapCounts[tap]!,
            selected: selected,
          );
          _airNote(
            canvas,
            g,
            point.x,
            point.height,
            depthAt(start),
            (note.designant || selected ? tint : ChartTimelinePainter.airColor)
                .withValues(alpha: alpha * noteOpacity),
            paint,
            note.designant ? ChartSprite.designant : ChartSprite.arcTap,
            angles: options,
          );
          if (timeline.onJudgementPlane(
            note,
            time,
            tap,
            editing ? g.judgementTolerance : g.noteDepth(20),
            timeTolerance: editing ? 1 : 50,
          )) {
            const width = PerspectiveGeometry.arcTapHalfWidth;
            highlights.add((
              left: g.projectArcTap(
                point.x - width,
                point.height,
                time,
                angles: options,
              ),
              right: g.projectArcTap(
                point.x + width,
                point.height,
                time,
                angles: options,
              ),
            ));
          }
          continue;
        }
        if (note.start == note.end) {
          final depth = depthAt(start);
          final visible = PerspectiveGeometry._clipNear(0, 1, (fraction) {
            final point = note.arcPoint(fraction);
            return g.viewDepth(
              point.x,
              point.height,
              depth,
              air: true,
              angles: options,
            );
          });
          if (visible == null) continue;
          final first = note.arcPoint(visible.start);
          final last = note.arcPoint(visible.end);
          final a = air(first.x, first.height, depth);
          final b = air(last.x, last.height, depth);
          if (note.variableArcTap) {
            stacks.add(
              note,
              (g.projectArcTap(first.x, first.height, depth, angles: options) +
                      g.projectArcTap(
                        last.x,
                        last.height,
                        depth,
                        angles: options,
                      )) /
                  2,
              selected: selected,
            );
            Offset vertex(double x, double h, double offset) => g.projectArcTap(
              x,
              h,
              depth,
              angles: options,
              modelDepth: offset,
            );
            List<Offset> face(double h) => [
              vertex(first.x, first.height + h, -0.6),
              vertex(last.x, last.height + h, -0.6),
              vertex(first.x, first.height + h, 0.6),
              vertex(last.x, last.height + h, 0.6),
            ];
            _block(
              canvas,
              face(-0.07),
              face(0.07),
              ChartSprite.arcTap,
              color,
              paint,
            );
            if (timeline.onJudgementPlane(
              note,
              time,
              note.start,
              editing ? g.judgementTolerance : g.noteDepth(20),
              timeTolerance: editing ? 1 : 50,
            )) {
              highlights.add((
                left: g.projectArcTap(
                  first.x,
                  first.height,
                  time,
                  angles: options,
                ),
                right: g.projectArcTap(
                  last.x,
                  last.height,
                  time,
                  angles: options,
                ),
              ));
            }
          } else if ((a - b).distanceSquared > 0.1) {
            line(a, b, color, 3);
            if (guide) {
              line(
                a,
                b,
                const Color(
                  0xFFFFE3A2,
                ).withValues(alpha: appearance.trace * 0.92),
                1.5,
              );
            }
          }
        } else if (start <= end) {
          if (!note.trace && start == note.start && noteOpacity > 0) {
            stacks.add(
              note,
              air(note.number(2), note.number(5), depthAt(start)),
              selected: selected,
            );
          }
          final segments = ((end - start) * note.smoothness / 24).ceil().clamp(
            1,
            100,
          );
          final left = <Offset>[], right = <Offset>[], ridge = <Offset>[];
          final halfWidth = note.designant
              ? 0.022
              : note.trace
              ? 0.15 / PerspectiveGeometry._skyWidth
              : chartArcHalfWidth;
          final halfHeight =
              halfWidth *
              PerspectiveGeometry._skyWidth /
              (PerspectiveGeometry._airHeight * 2);
          final points = <double>[
            for (var step = 0; step <= segments; step++)
              start + (end - start) * step / segments,
          ];
          for (final at in points.reversed) {
            final point = note.point(at);
            final depth = depthAt(at);
            left.add(
              air(point.x - halfWidth, point.height - halfHeight, depth),
            );
            right.add(
              air(point.x + halfWidth, point.height - halfHeight, depth),
            );
            ridge.add(air(point.x, point.height + halfHeight, depth));
          }
          if (!note.trace) {
            for (final (a, b, shade) in [
              (left, ridge, 0.76),
              (ridge, right, 1.0),
            ]) {
              final face = Color.lerp(Colors.black, tint, shade)!;
              final texture = selected
                  ? null
                  : skin.snakeTexture(
                      note.number(7).toInt(),
                      shaded: shade < 1.0,
                    );
              if (texture == null) {
                strip([...a, ...b.reversed], face.withValues(alpha: color.a));
              } else {
                texture.strip(
                  canvas,
                  [
                    for (var i = 0; i < a.length; i++) ...[a[i], b[i]],
                  ],
                  alpha: color.a,
                  start: (end - note.firstTime) / 350,
                  end: (start - note.firstTime) / 350,
                );
              }
            }
          } else {
            strip([...left, ...right.reversed], color);
          }
          if (guide && ridge.length > 1) {
            canvas.drawPath(
              Path()..addPolygon(ridge, false),
              Paint()
                ..color = const Color(
                  0xFFFFE3A2,
                ).withValues(alpha: appearance.trace * 0.92)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5,
            );
          }
        }
      } else if (note.kind == AffKind.flick) {
        if (start > end) continue;
        final point = note.point(start);
        _airNote(
          canvas,
          g,
          point.x,
          point.height,
          depthAt(start),
          ChartTimelinePainter.airColor.withValues(alpha: alpha),
          paint,
          ChartSprite.flick,
          angles: options,
        );
        final at = depthAt(start);
        final center = g.projectAir(point.x, point.height, at, angles: options);
        stacks.add(note, center, selected: visibility?.selected(note) == true);
        paintFlickArrow(
          canvas,
          center,
          g.flickDirection(
            point.x,
            point.height,
            at,
            Offset(note.number(3), note.number(4)),
            angles: options,
          ),
          g.flickArrowLength(point.x, point.height, at, angles: options),
          alpha,
        );
        if ((at - time).abs() <= g.noteDepth(27)) {
          intersections.add((
            point: g.projectAir(point.x, point.height, time, angles: options),
            opacity: 1.0,
          ));
        }
        if (visibility?.selected(note) == true) selectionMarks.add(center);
      } else {
        if (start > end) continue;
        final x = note.laneX;
        if (start == note.start) {
          stacks.add(
            note,
            g.project(x, .038, depthAt(start)),
            selected: visibility?.selected(note) == true,
          );
        }
        var head = depthAt(start), tail = head;
        for (final at in [...scroll.breaks(start, end), end]) {
          final depth = depthAt(at);
          head = math.min(head, depth);
          tail = math.max(tail, depth);
        }
        final flat = (tail - head).abs() < 1e-5;
        if (note.kind == AffKind.tap || flat) {
          head = math.max(g.near, head - g.noteDepth(22));
          tail = math.min(g.far, tail + g.noteDepth(22));
        }
        final points = [
          g.project(x - 0.112, 0, head),
          g.project(x + 0.112, 0, head),
          g.project(x - 0.112, 0, tail),
          g.project(x + 0.112, 0, tail),
        ];
        final sprite = note.kind == AffKind.hold
            ? ChartSprite.hold
            : ChartSprite.tap;
        final uvStartsNear = depthAt(start) <= depthAt(end);
        final duration = math.max(1, note.end - note.start);
        final holdAlpha =
            note.kind == AffKind.hold &&
                options?.fadingHolds == true &&
                g.time > note.start
            ? alpha * (1 - (g.time - note.start) / 240).clamp(0.12, 1.0)
            : alpha;
        final top = [
          g.project(x - 0.112, 0.038, head),
          g.project(x + 0.112, 0.038, head),
          g.project(x - 0.112, 0.038, tail),
          g.project(x + 0.112, 0.038, tail),
        ];
        _block(
          canvas,
          points,
          top,
          sprite,
          (visibility?.selected(note) == true
                  ? Colors.white
                  : ChartTimelinePainter.groundColor)
              .withValues(alpha: holdAlpha),
          paint,
          startUV: note.kind == AffKind.hold
              ? ((note.end - (uvStartsNear ? start : end)) / duration).clamp(
                  0.0,
                  1.0,
                )
              : 1,
          endUV: note.kind == AffKind.hold
              ? ((note.end - (uvStartsNear ? end : start)) / duration).clamp(
                  0.0,
                  1.0,
                )
              : 0,
          caps:
              note.kind != AffKind.hold ||
              flat ||
              start <= note.start ||
              end == note.end,
        );
        if (visibility?.selected(note) == true) {
          if ((start - note.start).abs() < 1e-5) {
            selectionMarks.add(g.project(x, 0.038, head));
          }
          if (note.kind == AffKind.hold && (end - note.end).abs() < 1e-5) {
            selectionMarks.add(g.project(x, 0.038, tail));
          }
        }
      }
    }

    final groundStart = g.project(leftLane, 0, g.time);
    final groundEnd = g.project(rightLane, 0, g.time);
    if (skin[ChartSprite.judgement] case final judgement?) {
      _judgementTexture(canvas, judgement, groundStart, groundEnd);
    } else {
      line(groundStart, groundEnd, ChartTimelinePainter.groundColor, 2);
    }
    for (final effect in scene.redLines(clock)) {
      final random = math.Random(effect.seed);
      final center = Offset(
        size.width * random.nextDouble(),
        size.height * random.nextDouble(),
      );
      final angle = random.nextDouble() * math.pi;
      final delta =
          Offset(math.cos(angle), math.sin(angle)) * size.longestSide * 0.45;
      line(
        center - delta,
        center + delta,
        const Color(0xFFFF3554).withValues(alpha: 0.75 * (1 - effect.progress)),
        2,
      );
    }
    final debris = scene.debris(clock);
    if (debris > 0) {
      final random = math.Random(71);
      for (var i = 0; i < 12; i++) {
        final x = size.width * random.nextDouble();
        final y =
            size.height * ((random.nextDouble() - time / (4200 + 180 * i)) % 1);
        final radius = 2 + random.nextDouble() * 7;
        strip([
          Offset(x - radius, y),
          Offset(x, y - radius * 1.7),
          Offset(x + radius, y),
          Offset(x, y + radius * 1.2),
        ], const Color(0xFFC5D3F3).withValues(alpha: debris * 0.5));
      }
    }
    if (editing) {
      if (wall) {
        final grid = const Color(0x4896DBFF);
        final height = g.wallHeight(arcTap: arcTapWall);
        Offset wallPoint(double x, double y) =>
            arcTapWall ? g.projectArcTap(x, y, time) : g.projectAir(x, y, time);
        for (var i = -2; i <= 6; i++) {
          line(wallPoint(i / 4, 0), wallPoint(i / 4, height), grid);
        }
        for (var i = 0; i <= (height * 2).floor(); i++) {
          line(wallPoint(-0.5, i / 2), wallPoint(1.5, i / 2), grid);
        }
      }
      final scroll = timeline.scroll(activeGroup);
      Offset? previous;
      for (final handle in handles) {
        final depth =
            time +
            direction * (scroll.at(handle.time.toDouble()) - scroll.at(time));
        if (depth < g.near || depth > g.far) continue;
        final at = g.projectAir(handle.x, handle.height, depth);
        if (previous != null) line(previous, at, const Color(0xFFFFD670), 2);
        canvas.drawCircle(at, 7, paint..color = const Color(0xFF0C1628));
        canvas.drawCircle(at, 4, paint..color = const Color(0xFFFFD670));
        previous = at;
      }
    }
    line(skyStart, skyEnd, const Color(0xFF251B32), 4.5);
    if (skin[ChartSprite.skyLine] case final skyLine?) {
      _judgementTexture(canvas, skyLine, skyStart, skyEnd);
    }
    line(skyStart, skyEnd, const Color(0xFFF9BEC9), 1.5);
    for (final (:point, :opacity) in intersections) {
      final texture = skin[ChartSprite.intersection];
      canvas.drawOval(
        Rect.fromCenter(
          center: point,
          width: 11 * g.horizontalScale,
          height: 11,
        ),
        paint..color = const Color(0xFF211B37).withValues(alpha: opacity),
      );
      if (texture != null) {
        texture.draw(
          canvas,
          Rect.fromCenter(
            center: point,
            width: 26 * g.horizontalScale,
            height: 3,
          ),
          alpha: opacity,
        );
      }
      canvas.drawOval(
        Rect.fromCenter(
          center: point,
          width: 4.8 * g.horizontalScale,
          height: 4.8,
        ),
        paint..color = const Color(0xFFFFE9BB).withValues(alpha: opacity),
      );
    }
    for (final (:left, :right) in highlights) {
      final radius = (g.width * 0.018).clamp(5.0, 12.0);
      final bounds = Rect.fromPoints(left, right).inflate(radius);
      final rim = RRect.fromRectAndRadius(bounds, Radius.circular(radius));
      canvas.drawRRect(
        rim,
        Paint()
          ..color = const Color(
            0x22FFC66A,
          ).withValues(alpha: noteOpacity * 0.13 * appearance.arcTap),
      );
      canvas.drawRRect(
        rim,
        Paint()
          ..color = const Color(
            0xFFFFE3A2,
          ).withValues(alpha: noteOpacity * appearance.arcTap)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7,
      );
    }
    for (final point in selectionMarks) {
      mark(point);
    }
    Offset? detached;
    for (final (:point, :tap, :outline, detached: isDetached)
        in keyframes?.call(g) ?? const <PerspectiveKeyframeMarker>[]) {
      if (isDetached) detached = point;
      if (tap) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            outline ?? Rect.fromCircle(center: point, radius: 11),
            const Radius.circular(8),
          ),
          Paint()
            ..color = const Color(0xFFFFE3A2)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.75,
        );
      }
      mark(point);
    }
    if (detached case final point?) drawChartSnapPoint(canvas, point);
    if (snapPoint case final point?) drawChartSnapPoint(canvas, point);
    stacks.paint(canvas, size);
    drawChartHits(
      canvas,
      skin,
      judgement,
      clock,
      (hit) => hit.arcTap
          ? g.projectArcTap(
              hit.x,
              hit.height,
              time,
              angles: timeline.groupOptions[hit.group],
            )
          : hit.air
          ? g.projectAir(
              hit.x,
              hit.height,
              time,
              angles: timeline.groupOptions[hit.group],
            )
          : g.project(hit.x, 0, time),
      horizontalScale: g.horizontalScale,
    );
    canvas.restore();
  }

  void _judgementTexture(
    Canvas canvas,
    ChartTexture texture,
    Offset a,
    Offset b,
  ) {
    final direction = b - a;
    final width = direction.distance;
    if (width < 0.1) return;
    final normal = Offset(-direction.dy, direction.dx) * (4 / width);
    texture.strip(canvas, [a - normal, b - normal, a + normal, b + normal]);
  }

  void _airNote(
    Canvas canvas,
    PerspectiveGeometry g,
    double x,
    double height,
    double time,
    Color color,
    Paint paint,
    ChartSprite sprite, {
    AffGroupOptions? angles,
  }) {
    final flick = sprite == ChartSprite.flick;
    final halfWidth = flick
        ? PerspectiveGeometry.flickHalfWidth
        : PerspectiveGeometry.arcTapHalfWidth;
    final model = skin.meshes[sprite];
    final texture = skin[sprite];
    const length = PerspectiveGeometry._arcTapDepth;
    const thickness = PerspectiveGeometry._arcTapHeight;
    Offset vertex(double x, double h, double z) => flick
        ? g.projectAir(
            x,
            height + h / 4.5,
            time + g.noteDepth(z * 32),
            angles: angles,
          )
        : g.projectArcTap(
            x,
            height,
            time,
            angles: angles,
            modelHeight: h,
            modelDepth: z,
          );
    if (model != null && texture != null) {
      final faces =
          model.triangles
              .map((face) {
                final positions = [
                  for (final corner in face)
                    g._arcTapPosition(
                      x + corner.point.x * halfWidth * 2,
                      height,
                      time,
                      angles,
                      corner.point.y * thickness,
                      -corner.point.z * length,
                    ),
                ];
                final points = [
                  for (final point in positions)
                    g.project(point.x, point.height, point.at),
                ];
                final a = points[1] - points[0], b = points[2] - points[0];
                final front = a.dx * b.dy - a.dy * b.dx < 0;
                final y = face.fold(0.0, (sum, vertex) => sum + vertex.point.y);
                final z = face.fold(0.0, (sum, vertex) => sum + vertex.point.z);
                final depth = positions.fold(
                  0.0,
                  (sum, point) =>
                      sum + g.viewDepth(point.x, point.height, point.at),
                );
                return (
                  points: points,
                  face: face,
                  front: front,
                  shade: y > 0.7
                      ? Colors.white
                      : z > 0.7
                      ? const Color(0xFFC6C6C6)
                      : const Color(0xFF999999),
                  depth: depth,
                );
              })
              .where((face) => face.front)
              .toList()
            ..sort((a, b) => b.depth.compareTo(a.depth));
      if (faces.isNotEmpty) {
        texture.triangles(
          canvas,
          [for (final face in faces) ...face.points],
          [
            for (final face in faces)
              for (final vertex in face.face) vertex.uv,
          ],
          [for (final face in faces) ...List.filled(3, face.shade)],
          color.a,
        );
        return;
      }
    }
    List<Offset> face(double h) => [
      vertex(x - halfWidth, h, -length / 2),
      vertex(x + halfWidth, h, -length / 2),
      vertex(x - halfWidth, h, length / 2),
      vertex(x + halfWidth, h, length / 2),
    ];
    _block(
      canvas,
      face(-thickness / 2),
      face(thickness / 2),
      sprite,
      color,
      paint,
    );
  }

  void _block(
    Canvas canvas,
    List<Offset> bottom,
    List<Offset> top,
    ChartSprite sprite,
    Color color,
    Paint paint, {
    double startUV = 1,
    double endUV = 0,
    bool caps = true,
  }) {
    final texture = skin[sprite];
    void draw(List<Offset> points, double light) {
      final shade = Color.lerp(Colors.black, Colors.white, light)!;
      if (texture != null) {
        texture.strip(
          canvas,
          points,
          alpha: color.a,
          tint: shade,
          start: startUV,
          end: endUV,
        );
      } else {
        final shaded = Color.lerp(
          Colors.black,
          color.withValues(alpha: 1),
          light,
        )!;
        canvas.drawPath(
          Path()
            ..addPolygon([points[0], points[1], points[3], points[2]], true),
          paint..color = shaded.withValues(alpha: color.a),
        );
      }
    }

    void visibleFace(List<Offset> points, double light) {
      final a = points[1] - points[0], b = points[2] - points[0];
      if (a.dx * b.dy - a.dy * b.dx < 0) draw(points, light);
    }

    visibleFace([bottom[2], bottom[0], top[2], top[0]], 0.56);
    visibleFace([bottom[1], bottom[3], top[1], top[3]], 0.56);
    if (caps) {
      visibleFace([bottom[0], bottom[1], top[0], top[1]], 0.72);
      visibleFace([bottom[3], bottom[2], top[3], top[2]], 0.64);
    }
    visibleFace([bottom[2], bottom[3], bottom[0], bottom[1]], 0.52);
    visibleFace(top, 1);
  }

  @override
  bool shouldRepaint(ChartPerspectivePainter oldDelegate) =>
      oldDelegate.playbackFraming != playbackFraming ||
      oldDelegate.noteOpacity != noteOpacity ||
      appearance != oldDelegate.appearance ||
      timeline != oldDelegate.timeline ||
      lookahead != oldDelegate.lookahead ||
      reverse != oldDelegate.reverse ||
      frozenAt != oldDelegate.frozenAt ||
      practiceSegment != oldDelegate.practiceSegment ||
      playbackView != oldDelegate.playbackView ||
      skin != oldDelegate.skin ||
      editing != oldDelegate.editing ||
      wall != oldDelegate.wall ||
      arcTapWall != oldDelegate.arcTapWall ||
      visibility != oldDelegate.visibility ||
      handles != oldDelegate.handles ||
      keyframes != oldDelegate.keyframes ||
      snapPoint != oldDelegate.snapPoint ||
      activeGroup != oldDelegate.activeGroup ||
      laneMode != oldDelegate.laneMode ||
      judgement != oldDelegate.judgement ||
      position != oldDelegate.position;
}
