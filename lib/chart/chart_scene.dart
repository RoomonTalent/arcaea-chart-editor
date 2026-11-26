import 'dart:math' as math;

import 'aff_chart.dart';

typedef CameraPose = ({
  double x,
  double y,
  double z,
  double pitch,
  double yaw,
  double roll,
});

const defaultCamera = (x: 0.0, y: 0.0, z: 0.0, pitch: 0.0, yaw: 0.0, roll: 0.0);

/// Evaluates effects at chart time, including when seeking or stepping backward.
class ChartScene {
  ChartScene(AffChart chart) {
    final events =
        chart.events
            .where(
              (event) =>
                  event.kind == AffKind.camera || event.kind == AffKind.scene,
            )
            .toList()
          ..sort((a, b) {
            final time = a.start.compareTo(b.start);
            return time == 0 ? a.sourceStart.compareTo(b.sourceStart) : time;
          });
    for (final event in events) {
      if (event.kind == AffKind.camera) {
        if (AffChart.cameraEasings.contains(event.arguments[7])) {
          _camera.add(event);
        }
        continue;
      }
      final type = event.arguments[1];
      if (!AffChart.sceneTypes.contains(type)) continue;
      final duration = event.arguments.length == 4
          ? math.max(0.0, event.number(2))
          : 0.0;
      final value = event.arguments.length == 4 ? event.number(3) : 0.0;
      final opacity = (value / 255).clamp(0.0, 1.0);
      final enabled = value == 0 ? 0.0 : 1.0;
      final time = event.start.toDouble();
      switch (type) {
        case 'trackhide':
          _track.add(time, 0, 0);
        case 'trackshow':
          _track.add(time, 0, 1);
        case 'trackdisplay':
          _track.add(time, duration, opacity);
        case 'hidegroup':
          final toggle = value == 0 || value == 1;
          _groups
              .putIfAbsent(event.group, () => _Channel(1))
              .add(time, duration, toggle ? 1 - enabled : opacity);
        case 'enwidenlane':
        case 'enwidenlanes':
          hasLaneEvents = true;
          _lanes.add(time, duration, enabled);
        case 'enwidencamera':
          _widenCamera.add(time, duration, enabled);
        case 'arcahvdistort':
          _distortion.add(time, duration * 1000, opacity);
        case 'arcahvdebris':
          _debris.add(time, duration * 1000, opacity);
        case 'redline':
          if (duration > 0) {
            _redLines.add((
              start: time,
              end: time + duration * 1000,
              seed: value.toInt(),
            ));
          }
      }
    }
  }

  final _track = _Channel(1), _lanes = _Channel(0), _widenCamera = _Channel(0);
  final _distortion = _Channel(0), _debris = _Channel(0);
  final _groups = <int, _Channel>{};
  final _camera = <AffEvent>[];
  bool hasLaneEvents = false;
  final _redLines = <({double start, double end, int seed})>[];

  double track(double time) => _track.at(time);
  double lanes(double time) => _lanes.at(time);
  double widenCamera(double time) => _widenCamera.at(time);
  double distortion(double time) => _distortion.at(time);
  double debris(double time) => _debris.at(time);
  double groupOpacity(int group, double time) => _groups[group]?.at(time) ?? 1;

  Iterable<({double progress, int seed})> redLines(double time) sync* {
    for (final line in _redLines) {
      if (line.start > time) break;
      if (line.end >= time) {
        yield (
          progress: (time - line.start) / (line.end - line.start),
          seed: line.seed,
        );
      }
    }
  }

  CameraPose camera(double time) {
    final pose = List<double>.filled(6, 0);
    for (final event in _camera) {
      if (event.start > time) break;
      final duration = event.number(8);
      final progress = duration == 0
          ? 1.0
          : ((time - event.start) / duration).clamp(0.0, 1.0);
      final easing = event.arguments[7];
      final factor = switch (easing) {
        'qi' => progress * progress * progress,
        'qo' => 1 - math.pow(1 - progress, 3).toDouble(),
        's' => (1 - math.cos(progress * math.pi)) / 2,
        _ => progress,
      };
      for (var axis = 0; axis < pose.length; axis++) {
        pose[axis] = easing == 'reset'
            ? pose[axis] * (1 - factor)
            : pose[axis] + event.number(axis + 1) * factor;
      }
    }
    return (
      x: pose[0],
      y: pose[1],
      z: pose[2],
      pitch: pose[3],
      yaw: pose[4],
      roll: pose[5],
    );
  }
}

class _Channel {
  _Channel(this.initial);

  final double initial;
  final _keys = <({double time, double duration, double from, double to})>[];

  void add(double time, double duration, double value) {
    final from = at(time);
    _keys.add((time: time, duration: duration, from: from, to: value));
  }

  double at(double time) {
    var low = 0;
    var high = _keys.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_keys[mid].time <= time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == 0) return initial;
    final key = _keys[low - 1];
    if (key.duration == 0 || time >= key.time + key.duration) return key.to;
    return key.from + (key.to - key.from) * (time - key.time) / key.duration;
  }
}
