import 'dart:math' as math;

import 'aff_chart.dart';

/// In AFF each BPM event starts a new grid. Stops keep the last usable grid
/// so the editor can still step through their timestamps.
class ChartBeatGrid {
  ChartBeatGrid(
    List<AffEvent> timings, {
    required int subdivision,
    required double bpmBase,
  }) : _fallback = _step(math.max(1.0, bpmBase), subdivision) {
    final offsets = <int, double>{};
    for (final timing in timings) {
      final bpm = timing.number(1).abs();
      if (bpm >= 1) {
        offsets[timing.start] = _step(bpm, subdivision);
      }
    }
    _segments = [
      for (final entry in offsets.entries)
        (start: entry.key, step: entry.value),
    ];
  }

  final double _fallback;
  late final List<({int start, double step})> _segments;

  // AFF timestamps have millisecond precision.
  static double _step(double bpm, int subdivision) =>
      math.max(1.0, 240000 / bpm / subdivision);

  int _index(double time) {
    var low = 0, high = _segments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_segments[mid].start <= time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  ({int start, double step}) _segment(int index) => _segments.isEmpty
      ? (start: 0, step: _fallback)
      : _segments[math.max(0, index)];

  int nearest(double time) {
    final index = _index(time);
    final grid = _segment(index);
    final step = ((time - grid.start) / grid.step).round();
    final candidate = (grid.start + step * grid.step).round();
    if (index + 1 < _segments.length) {
      return math.min(candidate, _segments[index + 1].start);
    }
    return candidate;
  }

  int next(double time, {required bool forward}) {
    // Compare on the integer-millisecond lattice used by AFF. This prevents
    // fractional BPM steps from sticking or skipping when the display rounds.
    final edge = forward ? time.floor() + 0.5 : time.ceil() - 0.5;
    final index = _index(forward ? time : time.ceil() - 1.0);
    final grid = _segment(index);
    final fraction = (edge - grid.start) / grid.step;
    var n = forward ? fraction.ceil() - 1 : fraction.floor() + 1;
    int candidate;
    do {
      n += forward ? 1 : -1;
      candidate = (grid.start + n * grid.step).round();
    } while (forward ? candidate <= time : candidate >= time);
    if (forward && index + 1 < _segments.length) {
      return math.min(candidate, _segments[index + 1].start);
    }
    return candidate;
  }
}
