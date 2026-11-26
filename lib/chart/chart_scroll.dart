import 'dart:math' as math;

import 'aff_chart.dart';

typedef ScrollRange = ({double start, double end});

/// Integrates signed BPM over chart time. A zero BPM freezes the distance.
class ChartScroll {
  ChartScroll(List<AffEvent> timings, double bpmBase)
    : _rate = (timings.firstOrNull?.number(1) ?? bpmBase) / bpmBase,
      _increasing = timings.every((timing) => timing.number(1) >= 0) {
    var previousTime = 0.0;
    var previousRate = _rate;
    var distance = 0.0;
    for (final timing in timings) {
      final time = timing.start.toDouble();
      distance += (time - previousTime) * previousRate;
      previousRate = timing.number(1) / bpmBase;
      _segments.add((time: time, distance: distance, rate: previousRate));
      previousTime = time;
    }
  }

  final double _rate;
  final bool _increasing;
  final _segments = <({double time, double distance, double rate})>[];

  int _index(double time) {
    var low = 0;
    var high = _segments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_segments[mid].time <= time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  double at(double time) {
    final index = _index(time);
    if (index < 0) return _rate * time;
    final segment = _segments[index];
    return segment.distance + (time - segment.time) * segment.rate;
  }

  Iterable<double> breaks(double start, double end) sync* {
    for (var i = _index(start) + 1; i < _segments.length; i++) {
      final time = _segments[i].time;
      if (time >= end) break;
      yield time;
    }
  }

  Iterable<ScrollRange> visible(
    double low,
    double high,
    double start,
    double end,
  ) sync* {
    if (start > end) return;
    var left = start;
    var distance = at(start);
    if (_increasing && distance < low) {
      var a = 0, b = _segments.length;
      while (a < b) {
        final middle = (a + b) ~/ 2;
        if (_segments[middle].distance < low) {
          a = middle + 1;
        } else {
          b = middle;
        }
      }
      if (a > 0 && _segments[a - 1].time > left) {
        left = math.min(end, _segments[a - 1].time);
        distance = at(left);
      }
    }
    ScrollRange? pending;
    Iterable<double> boundaries() sync* {
      yield* breaks(left, end);
      yield end;
    }

    for (final right in boundaries()) {
      if (_increasing && distance > high) break;
      final nextDistance = at(right);
      if (math.max(distance, nextDistance) >= low &&
          math.min(distance, nextDistance) <= high) {
        final delta = nextDistance - distance;
        var from = left, to = right;
        if (delta != 0) {
          final a = (low - distance) / delta;
          final b = (high - distance) / delta;
          from += (right - left) * math.max(0.0, math.min(a, b));
          to = left + (right - left) * math.min(1.0, math.max(a, b));
        }
        if (pending == null) {
          pending = (start: from, end: to);
        } else if (from <= pending.end + 1e-5) {
          pending = (start: pending.start, end: to);
        } else {
          yield pending;
          pending = (start: from, end: to);
        }
      }
      left = right;
      distance = nextDistance;
    }
    if (pending != null) yield pending;
  }
}
