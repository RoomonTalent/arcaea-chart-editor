import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'aff_chart.dart';

typedef ChartPracticeSegment = ({double start, double end});

extension ChartSegmentNotes on ChartPracticeSegment {
  bool includes(num time) => start <= time && time < end;

  bool showsBody(AffEvent note) {
    if (note.kind == AffKind.arc && note.start != note.end) {
      return note.firstTime < end && note.lastTime > start;
    }
    return includes(note.start);
  }

  bool shows(AffEvent note) => showsBody(note) || note.arcTaps.any(includes);
}

class PracticeDensityTrack extends StatefulWidget {
  const PracticeDensityTrack({
    super.key,
    required this.min,
    required this.max,
    required this.position,
    required this.density,
    required this.segment,
    required this.onSeek,
    required this.onSegment,
  });

  final double min, max, position;
  final List<int> density;
  final ChartPracticeSegment? segment;
  final ValueChanged<double>? onSeek;
  final ValueChanged<ChartPracticeSegment> onSegment;

  @override
  State<PracticeDensityTrack> createState() => _PracticeDensityTrackState();
}

enum _Marker { position, start, end }

const _inset = 16.0;
String _seconds(double time) => '${(time / 1000).toStringAsFixed(2)} s';

class _PracticeDensityTrackState extends State<PracticeDensityTrack> {
  _Marker _marker = _Marker.position;
  double? _draft;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 104,
    width: double.infinity,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth - 2 * _inset);
        final duration = widget.max - widget.min;
        double x(double time) =>
            _inset +
            (duration <= 0
                    ? 0
                    : ((time - widget.min) / duration).clamp(0.0, 1.0)) *
                width;
        double time(double dx) =>
            widget.min + ((dx - _inset) / width).clamp(0.0, 1.0) * duration;

        void begin(Offset point) {
          _marker = _Marker.position;
          if (widget.segment case final segment? when point.dy < 80) {
            final a = (point.dx - x(segment.start)).abs();
            final b = (point.dx - x(segment.end)).abs();
            if (math.min(a, b) < 23) {
              _marker = a <= b ? _Marker.start : _Marker.end;
            }
          }
        }

        void move(double dx) {
          final at = time(dx);
          final segment = widget.segment;
          if (segment == null || _marker == _Marker.position) {
            setState(() => _draft = at);
          } else {
            final gap = math.min(duration, 1.0);
            widget.onSegment(
              _marker == _Marker.start
                  ? (
                      start: at.clamp(widget.min, segment.end - gap),
                      end: segment.end,
                    )
                  : (
                      start: segment.start,
                      end: at.clamp(segment.start + gap, widget.max),
                    ),
            );
          }
        }

        void finish() {
          final time = _draft;
          if (time == null) return;
          setState(() => _draft = null);
          widget.onSeek?.call(time);
        }

        final enabled = widget.onSeek != null && duration > 0;
        final position = _draft ?? widget.position;
        final next = (position + 1000).clamp(widget.min, widget.max);
        final previous = (position - 1000).clamp(widget.min, widget.max);
        return Semantics(
          label: '物量进度图',
          value: _seconds(position),
          increasedValue: enabled ? _seconds(next) : null,
          decreasedValue: enabled ? _seconds(previous) : null,
          onIncrease: enabled ? () => widget.onSeek!(next) : null,
          onDecrease: enabled ? () => widget.onSeek!(previous) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: enabled
                ? (event) {
                    begin(event.localPosition);
                    move(event.localPosition.dx);
                    finish();
                  }
                : null,
            onHorizontalDragDown: enabled
                ? (event) => begin(event.localPosition)
                : null,
            onHorizontalDragUpdate: enabled
                ? (event) => move(event.localPosition.dx)
                : null,
            onHorizontalDragEnd: enabled ? (_) => finish() : null,
            onHorizontalDragCancel: () {
              if (_draft != null) setState(() => _draft = null);
            },
            child: CustomPaint(
              painter: _DensityPainter(
                widget.density,
                widget.min,
                widget.max,
                _draft ?? widget.position,
                widget.segment,
                Theme.of(context).colorScheme,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    ),
  );
}

class _DensityPainter extends CustomPainter {
  const _DensityPainter(
    this.bins,
    this.min,
    this.max,
    this.position,
    this.segment,
    this.colors,
  );
  final List<int> bins;
  final double min, max, position;
  final ChartPracticeSegment? segment;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTRB(
      _inset,
      19,
      math.max(_inset + 1, size.width - _inset),
      size.height - 20,
    );
    final paint = Paint()..color = colors.surfaceContainerHighest;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(6)),
      paint,
    );
    final peak = bins.fold(1, math.max);
    double x(double at) =>
        bounds.left +
        ((at - min) / math.max(1.0, max - min)).clamp(0.0, 1.0) * bounds.width;
    final step = bounds.width / math.max(1, bins.length);
    paint.color = colors.primary.withValues(alpha: .65);
    for (final (index, value) in bins.indexed) {
      if (value == 0) continue;
      final height = bounds.height * value / peak;
      canvas.drawRect(
        Rect.fromLTWH(
          bounds.left + index * step,
          bounds.bottom - height,
          math.max(.5, step - .7),
          height,
        ),
        paint,
      );
    }
    paint.color = colors.outline;
    canvas.drawLine(bounds.bottomLeft, bounds.bottomRight, paint);
    canvas.drawLine(bounds.topLeft, bounds.bottomLeft, paint);

    void label(String text, double left, double top) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: colors.onSurface, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(left.clamp(0.0, math.max(0.0, size.width - painter.width)), top),
      );
      painter.dispose();
    }

    label('物量', 2, 2);
    label(_seconds(min), 2, bounds.bottom + 4);
    label(_seconds(max), bounds.right - 28, bounds.bottom + 4);
    if (segment case final value?) {
      final a = x(value.start), b = x(value.end);
      canvas.drawRect(
        Rect.fromLTRB(a, bounds.top, b, bounds.bottom),
        paint..color = colors.tertiary.withValues(alpha: .18),
      );
      for (final (at, name) in [(a, 'A'), (b, 'B')]) {
        canvas.drawLine(
          Offset(at, bounds.top - 4),
          Offset(at, bounds.bottom),
          paint
            ..color = colors.tertiary
            ..strokeWidth = 2,
        );
        canvas.drawCircle(Offset(at, bounds.top - 3), 5, paint);
        label(name, at + 5, 1);
      }
    }
    final cursor = x(position);
    canvas.drawLine(
      Offset(cursor, bounds.top),
      Offset(cursor, bounds.bottom),
      paint
        ..color = colors.onSurface
        ..strokeWidth = 1.5,
    );
    label(_seconds(position), cursor - 14, bounds.bottom - 15);
  }

  @override
  bool shouldRepaint(_DensityPainter other) =>
      other.bins != bins ||
      other.position != position ||
      other.segment != segment ||
      other.min != min ||
      other.max != max ||
      other.colors != colors;
}
