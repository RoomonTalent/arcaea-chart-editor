import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_skin.dart';

enum PracticeGrade {
  shiny('PURE+', Color(0xFF98EDFF), ChartSprite.hitPure),
  pure('PURE', Color(0xFF9FF4B5), ChartSprite.hitPure),
  far('FAR', Color(0xFFFFD479), ChartSprite.hitFar),
  lost('LOST', Color(0xFFFF8390), ChartSprite.hitLost);

  const PracticeGrade(this.label, this.color, this.sprite);
  final String label;
  final Color color;
  final ChartSprite sprite;

  static const shinyWindow = 25.0, pureWindow = 50.0, farWindow = 100.0;
  static const inputWindow = 120.0;

  static PracticeGrade at(double? offset) {
    if (offset == null || offset.abs() > farWindow) return lost;
    if (offset.abs() <= shinyWindow) return shiny;
    return offset.abs() <= pureWindow ? pure : far;
  }
}

enum PracticeKey {
  ground('地键', Color(0xFF59DCC8)),
  air('天键', Color(0xFFFFCC71)),
  hold('长按', Color(0xFF9EAAFF)),
  snake('蛇', Color(0xFFF5A2CB)),
  flick('滑键', Color(0xFFEC9C76));

  const PracticeKey(this.label, this.color);
  final String label;
  final Color color;

  bool get isSustain => this == hold || this == snake;

  PracticeGrade grade(double? offset) => isSustain
      ? offset != null && offset.abs() <= PracticeGrade.shinyWindow
            ? PracticeGrade.shiny
            : PracticeGrade.lost
      : PracticeGrade.at(offset);
}

typedef PracticeWindowSide = ({
  double shiny,
  double pure,
  double far,
  double capture,
});
typedef PracticeWindows = ({
  PracticeWindowSide early,
  PracticeWindowSide? late,
});

extension PracticeWindowSides on PracticeWindows {
  PracticeWindowSide get after => late ?? early;
}

typedef PracticeSustainWindow = ({double early, double late});

PracticeWindows defaultPracticeWindows(PracticeKey key) => key.isSustain
    ? sustainPracticeWindows(PracticeGrade.shinyWindow)
    : (
        early: (
          shiny: PracticeGrade.shinyWindow,
          pure: PracticeGrade.pureWindow,
          far: PracticeGrade.farWindow,
          capture: PracticeGrade.inputWindow,
        ),
        late: null,
      );

PracticeWindows sustainPracticeWindows(double window) =>
    (early: sustainWindowSide(window), late: null);

PracticeWindowSide sustainWindowSide(double window) =>
    (shiny: window, pure: window, far: window, capture: window);

List<double> _encodeWindowSide(PracticeWindowSide side) => [
  side.shiny,
  side.pure,
  side.far,
  side.capture,
];

String encodePracticeWindows(Map<PracticeKey, PracticeWindows> settings) =>
    jsonEncode({
      for (final entry in settings.entries)
        entry.key.name: [
          ..._encodeWindowSide(entry.value.early),
          if (entry.value.late case final late?) ..._encodeWindowSide(late),
        ],
    });

Map<PracticeKey, PracticeWindows> decodePracticeWindows(String? source) {
  if (source == null) return {};
  final result = <PracticeKey, PracticeWindows>{};
  try {
    final data = jsonDecode(source);
    if (data is! Map) return result;
    for (final key in PracticeKey.values) {
      final row = data[key.name];
      if (row is! List ||
          (row.length != 4 && row.length != 8) ||
          row.any((v) => v is! num || !v.isFinite || v < 0 || v > 1000)) {
        continue;
      }
      final values = [for (final value in row.cast<num>()) value.toDouble()];
      PracticeWindowSide? sideAt(int index) {
        final shiny = values[index], pure = values[index + 1];
        final far = values[index + 2], capture = values[index + 3];
        if (key.isSustain) return sustainWindowSide(shiny);
        if (shiny > pure || pure > far || far > capture) return null;
        return (shiny: shiny, pure: pure, far: far, capture: capture);
      }

      final early = sideAt(0);
      final late = values.length == 8 ? sideAt(4) : null;
      if (early != null && (values.length == 4 || late != null)) {
        result[key] = (early: early, late: late);
      }
    }
  } on FormatException {
    return {};
  }
  return result;
}

PracticeGrade practiceGradeAt(
  PracticeWindows windows,
  double? offset, {
  PracticeSustainWindow? sustainWindow,
}) {
  if (offset == null) return PracticeGrade.lost;
  if (sustainWindow != null) {
    return -sustainWindow.late <= offset && offset <= sustainWindow.early
        ? PracticeGrade.shiny
        : PracticeGrade.lost;
  }
  final side = offset < 0 ? windows.after : windows.early;
  final distance = offset.abs();
  if (distance <= side.shiny) return PracticeGrade.shiny;
  if (distance <= side.pure) return PracticeGrade.pure;
  if (distance <= side.far) return PracticeGrade.far;
  return PracticeGrade.lost;
}

typedef PracticeResult = ({
  PracticeKey key,
  PracticeGrade grade,
  double? offset,
  double at,
  Offset? point,
  PracticeWindows windows,
  PracticeSustainWindow? sustainWindow,
});

class PracticeJudgements {
  final history = <PracticeResult>[];
  final _counts = List<int>.filled(PracticeGrade.values.length, 0);
  int combo = 0, bestCombo = 0, early = 0, late = 0;

  int count(PracticeGrade grade) => _counts[grade.index];
  int get lost => count(PracticeGrade.lost);
  int get hits => history.length - lost;
  String get summary =>
      '大 P ${count(PracticeGrade.shiny)} · 小 P ${count(PracticeGrade.pure)}'
      ' · FAR ${count(PracticeGrade.far)} · LOST $lost · EARLY $early · LATE $late';

  PracticeGrade record(
    PracticeKey key,
    double? offset,
    double at,
    Offset? point, {
    bool sustainHit = false,
    PracticeWindows? windows,
    PracticeSustainWindow? sustainWindow,
  }) {
    final timing = windows ?? defaultPracticeWindows(key);
    final grade = sustainHit
        ? PracticeGrade.shiny
        : practiceGradeAt(timing, offset, sustainWindow: sustainWindow);
    history.add((
      key: key,
      grade: grade,
      offset: offset,
      at: at,
      point: point,
      windows: timing,
      sustainWindow: sustainWindow,
    ));
    _counts[grade.index]++;
    if (grade == PracticeGrade.lost) {
      combo = 0;
    } else {
      bestCombo = math.max(bestCombo, ++combo);
    }
    if (offset != null &&
        (grade == PracticeGrade.pure || grade == PracticeGrade.far)) {
      if (offset > 0) early++;
      if (offset < 0) late++;
    }
    return grade;
  }

  void reviseSustain(int index, double offset, Offset? point) {
    final previous = history[index];
    history[index] = (
      key: previous.key,
      grade: previous.grade,
      offset: offset,
      at: previous.at,
      point: point,
      windows: previous.windows,
      sustainWindow: previous.sustainWindow,
    );
  }

  void clear() {
    history.clear();
    _counts.fillRange(0, _counts.length, 0);
    combo = bestCombo = early = late = 0;
  }
}

enum FeedbackItem {
  grade('判定文字', (x: .5, y: .38, size: 25, width: .60, mode: 0, show: true)),
  combo('连击', (x: .5, y: .19, size: 44, width: .60, mode: 2, show: true)),
  timing('EARLY／LATE 偏差', (
    x: .5,
    y: .44,
    size: 15,
    width: .60,
    mode: 1,
    show: false,
  )),
  bar('判定条', (x: .5, y: .94, size: 12, width: .60, mode: 2, show: false));

  const FeedbackItem(this.label, this.defaults);
  final String label;
  final FeedbackPlacement defaults;
}

typedef FeedbackPlacement = ({
  double x,
  double y,
  double size,
  double width,
  int mode,
  bool show,
});

class FeedbackSettings {
  const FeedbackSettings([this.values = const {}]);
  final Map<FeedbackItem, FeedbackPlacement> values;

  FeedbackPlacement operator [](FeedbackItem item) =>
      values[item] ?? item.defaults;

  static FeedbackSettings decode(String? source) {
    if (source == null) return const FeedbackSettings();
    try {
      final data = jsonDecode(source) as Map<String, dynamic>;
      return FeedbackSettings({
        for (final item in FeedbackItem.values)
          if (data[item.name] case final List entry when entry.length == 6)
            item: (
              x: (entry[0] as num).toDouble().clamp(0, 1),
              y: (entry[1] as num).toDouble().clamp(0, 1),
              size: (entry[2] as num).toDouble().clamp(6, 88),
              width: (entry[3] as num).toDouble().clamp(.2, .95),
              mode: (entry[4] as int).clamp(0, 2),
              show: entry[5] as bool,
            ),
      });
    } catch (_) {
      return const FeedbackSettings();
    }
  }

  String encode() => jsonEncode({
    for (final entry in values.entries)
      entry.key.name: [
        entry.value.x,
        entry.value.y,
        entry.value.size,
        entry.value.width,
        entry.value.mode,
        entry.value.show,
      ],
  });
}

Rect practiceFeedbackBounds(
  FeedbackItem item,
  FeedbackSettings settings,
  Size size, {
  Offset? hit,
}) {
  final value = settings[item];
  final (width, height) = switch (item) {
    FeedbackItem.grade => (value.size * 4, value.size + 6),
    FeedbackItem.combo => (value.size * 4, value.size * 1.25),
    FeedbackItem.timing => (value.size * 7, value.size + 4),
    FeedbackItem.bar => (size.width * value.width, value.size),
  };
  var center = Offset(size.width * value.x, size.height * value.y);
  if (item == FeedbackItem.grade && hit != null && value.mode != 2) {
    center = hit - Offset(0, value.size * 1.2);
  } else if (item == FeedbackItem.timing && value.mode != 2) {
    final grade = practiceFeedbackBounds(
      FeedbackItem.grade,
      settings,
      size,
      hit: hit,
    );
    center =
        grade.center +
        Offset(
          0,
          (settings[FeedbackItem.grade].size * .65 + value.size * .7) *
              (value.mode == 0 ? -1 : 1),
        );
  }
  final insetX = math.min(width / 2, size.width / 2);
  final insetY = math.min(height / 2, size.height / 2);
  return Rect.fromCenter(
    center: Offset(
      center.dx.clamp(insetX, size.width - insetX),
      center.dy.clamp(insetY, size.height - insetY),
    ),
    width: width,
    height: height,
  );
}

class PracticeFeedbackPainter extends CustomPainter {
  PracticeFeedbackPainter(
    this.position,
    this.judgements,
    this.settings,
    this.skin,
    Listenable scores, {
    this.preview = false,
    this.defaultWindows,
  }) : super(repaint: Listenable.merge([position, scores]));

  final ValueNotifier<double> position;
  final PracticeJudgements judgements;
  final FeedbackSettings settings;
  final ChartSkin skin;
  final bool preview;
  final PracticeWindows? defaultWindows;

  @override
  void paint(Canvas canvas, Size size) {
    final combo = settings[FeedbackItem.combo];
    if ((combo.show || preview) && judgements.combo > 3) {
      _label(
        canvas,
        '${judgements.combo}',
        practiceFeedbackBounds(FeedbackItem.combo, settings, size).center,
        combo.size,
        const Color(0xFFF3EEFF).withValues(alpha: combo.show ? 1 : .48),
      );
    }
    final bar = settings[FeedbackItem.bar];
    if (bar.show || preview) {
      final rect = practiceFeedbackBounds(FeedbackItem.bar, settings, size);
      if (!bar.show) {
        canvas.saveLayer(
          rect.inflate(2),
          Paint()..color = const Color(0x7AFFFFFF),
        );
      }
      _paintTimingBar(canvas, rect);
      if (!bar.show) canvas.restore();
    }
    final grade = settings[FeedbackItem.grade],
        timing = settings[FeedbackItem.timing];
    if (!grade.show && !timing.show && !preview) return;
    var fixedGradeDrawn = false;
    var fixedTimingDrawn = false;
    for (final result in judgements.history.reversed.take(12)) {
      final age = position.value - result.at;
      if (age > 460) break;
      final opacity = (1 - age / 560).clamp(0.0, 1.0);
      final gradeFixed = grade.mode == 2 || result.point == null;
      final timingFixed = timing.mode == 2 || gradeFixed;
      if ((grade.show || preview) && (!gradeFixed || !fixedGradeDrawn)) {
        final anchor = practiceFeedbackBounds(
          FeedbackItem.grade,
          settings,
          size,
          hit: result.point,
        ).center;
        _spriteLabel(
          canvas,
          result.grade.label,
          result.grade.sprite,
          anchor,
          grade.size,
          result.grade.color,
          opacity * (grade.show ? 1 : .48),
        );
        fixedGradeDrawn |= gradeFixed;
      }
      final offset = result.offset;
      if ((timing.show || preview) &&
          (!timingFixed || !fixedTimingDrawn) &&
          offset != null &&
          (preview ||
              result.grade == PracticeGrade.pure ||
              result.grade == PracticeGrade.far) &&
          offset.abs() >= .5) {
        final early = offset > 0;
        final color = early ? const Color(0xFFAFEBFF) : const Color(0xFFFFB4B0);
        final at = practiceFeedbackBounds(
          FeedbackItem.timing,
          settings,
          size,
          hit: result.point,
        ).center;
        final timingOpacity = opacity * (timing.show ? 1 : .48);
        final sprite = early ? ChartSprite.hitEarly : ChartSprite.hitLate;
        final label = early ? 'EARLY' : 'LATE';
        final ms = offset.abs().toStringAsFixed(1);
        if (skin[sprite] != null) {
          _spriteLabel(
            canvas,
            label,
            sprite,
            at.translate(-timing.size * 1.45, 0),
            timing.size,
            color,
            timingOpacity,
          );
          _label(
            canvas,
            '$ms ms',
            at.translate(timing.size * 1.65, 0),
            timing.size,
            color.withValues(alpha: timingOpacity),
          );
        } else {
          _label(
            canvas,
            '$label $ms ms',
            at,
            timing.size,
            color.withValues(alpha: timingOpacity),
          );
        }
        fixedTimingDrawn |= timingFixed;
      }
    }
  }

  void _spriteLabel(
    Canvas canvas,
    String label,
    ChartSprite sprite,
    Offset at,
    double size,
    Color color,
    double opacity,
  ) {
    final texture = skin[sprite];
    if (texture == null) {
      _label(canvas, label, at, size, color.withValues(alpha: opacity));
      return;
    }
    texture.draw(
      canvas,
      Rect.fromCenter(center: at, width: size * 3.8, height: size),
      alpha: opacity,
      fromY: .27,
      toY: .67,
    );
    if (label == 'PURE+') {
      _label(
        canvas,
        '+',
        at.translate(size * 2, 0),
        size * .85,
        color.withValues(alpha: opacity),
      );
    }
  }

  void _paintTimingBar(Canvas canvas, Rect rect) {
    final latest = judgements.history.lastOrNull;
    final windows =
        latest?.windows ??
        defaultWindows ??
        defaultPracticeWindows(PracticeKey.ground);
    final sustainWindow = latest?.sustainWindow;
    paintPracticeTimingBar(canvas, rect, windows, sustainWindow: sustainWindow);
    final paint = Paint();
    for (final result in judgements.history.reversed.take(36)) {
      final offset = result.offset;
      if (offset == null) continue;
      final opacity = (1 - (position.value - result.at) / 1200).clamp(0.0, 1.0);
      if (opacity == 0) continue;
      final x = _barX(rect, windows, offset, sustainWindow);
      canvas.drawLine(
        Offset(x, rect.top - 3),
        Offset(x, rect.bottom + 3),
        paint
          ..color = result.grade.color.withValues(alpha: opacity)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(PracticeFeedbackPainter oldDelegate) =>
      preview != oldDelegate.preview ||
      defaultWindows != oldDelegate.defaultWindows ||
      settings != oldDelegate.settings ||
      skin != oldDelegate.skin ||
      position != oldDelegate.position ||
      judgements != oldDelegate.judgements;
}

double _barX(
  Rect rect,
  PracticeWindows windows,
  double offset,
  PracticeSustainWindow? sustainWindow,
) {
  double extent(PracticeWindowSide side) =>
      side.capture > side.far ? side.capture : side.far + 20;
  final max = sustainWindow != null
      ? math.max(sustainWindow.early, sustainWindow.late) + 20
      : math.max(extent(windows.early), extent(windows.after));
  return rect.center.dx - offset.clamp(-max, max) / max * rect.width / 2;
}

void paintPracticeTimingBar(
  Canvas canvas,
  Rect rect,
  PracticeWindows windows, {
  PracticeSustainWindow? sustainWindow,
}) {
  double x(double offset) => _barX(rect, windows, offset, sustainWindow);
  final paint = Paint()..color = const Color(0xFF9F404E);
  canvas.drawRect(rect, paint);
  for (final (early, late, color) in [
    if (sustainWindow == null) ...[
      (windows.early.far, windows.after.far, const Color(0xFFAE802E)),
      (windows.early.pure, windows.after.pure, const Color(0xFF3C9167)),
      (windows.early.shiny, windows.after.shiny, const Color(0xFF64BE87)),
    ] else
      (sustainWindow.early, sustainWindow.late, const Color(0xFF64BE87)),
  ]) {
    canvas.drawRect(
      Rect.fromLTRB(x(early), rect.top, x(-late), rect.bottom),
      paint..color = color,
    );
  }
  canvas.drawLine(
    rect.topCenter,
    rect.bottomCenter,
    paint
      ..color = Colors.white
      ..strokeWidth = 2,
  );
}

void _label(
  Canvas canvas,
  String text,
  Offset center,
  double size,
  Color color,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: FontWeight.bold,
        shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width, painter.height) / 2);
  painter.dispose();
}

Future<void> showPracticeResults(
  BuildContext context,
  PracticeJudgements report,
) async {
  final history = report.history.toList(growable: false);
  final counts = <PracticeKey, int>{};
  final points = <({PracticeKey key, int index, double offset})>[];
  for (final event in history) {
    final offset = event.offset;
    if (offset == null) continue;
    final index = counts.update(
      event.key,
      (previous) => previous + 1,
      ifAbsent: () => 1,
    );
    points.add((key: event.key, index: index, offset: offset));
  }
  final hidden = <PracticeKey>{};
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('试玩结果'),
        scrollable: true,
        content: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${report.summary} · 最长连击 ${report.bestCombo}'),
              const SizedBox(height: 12),
              if (points.isEmpty)
                const Text('没有可绘制的判定偏差')
              else ...[
                const Text('偏差（ms） · 正值为提前'),
                SizedBox(
                  height: 220,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _DelayPlot(points, counts, hidden.toSet()),
                  ),
                ),
                const Center(child: Text('各键型的第几次判定')),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final key in PracticeKey.values)
                      if (counts.containsKey(key))
                        FilterChip(
                          avatar: Icon(
                            Icons.circle,
                            size: 10,
                            color: key.color,
                          ),
                          label: Text('${key.label} ${counts[key]}'),
                          selected: !hidden.contains(key),
                          onSelected: (show) => update(
                            () => show ? hidden.remove(key) : hidden.add(key),
                          ),
                        ),
                  ],
                ),
              ],
              const Text('未触发的 LOST 只计入统计。已持续接住的判定点记为 0 ms。'),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );
}

class _DelayPlot extends CustomPainter {
  const _DelayPlot(this.points, this.counts, this.hidden);
  final List<({PracticeKey key, int index, double offset})> points;
  final Map<PracticeKey, int> counts;
  final Set<PracticeKey> hidden;

  @override
  void paint(Canvas canvas, Size size) {
    final maxOffset = points
        .where((point) => !hidden.contains(point.key))
        .fold(
          PracticeGrade.inputWindow,
          (max, point) => math.max(max, point.offset.abs()),
        );
    final limit = (maxOffset / 20).ceilToDouble() * 20;
    final rect = Rect.fromLTRB(40, 12, size.width - 12, size.height - 21);
    if (rect.isEmpty) return;
    final count = counts.values.fold(1, math.max);
    double y(double offset) =>
        rect.center.dy - offset / limit * rect.height / 2;
    final paint = Paint();
    for (var step = -3; step <= 3; step++) {
      final offset = step * limit / 3;
      final at = y(offset);
      canvas.drawLine(
        Offset(rect.left, at),
        Offset(rect.right, at),
        paint
          ..color = offset == 0
              ? const Color(0xFF8493B2)
              : const Color(0xFF40516A),
      );
      _label(
        canvas,
        '${offset.round()}',
        Offset(20, at),
        10,
        const Color(0xFFD4DEF0),
      );
    }
    for (final point in points) {
      if (hidden.contains(point.key)) continue;
      final x =
          rect.left +
          (count <= 1 ? .5 : (point.index - 1) / (count - 1)) * rect.width;
      canvas.drawCircle(
        Offset(x, y(point.offset)),
        2,
        paint..color = point.key.color.withValues(alpha: .85),
      );
    }
    _label(
      canvas,
      '1',
      Offset(rect.left, rect.bottom + 10),
      10,
      const Color(0xFFD4DEF0),
    );
    if (count > 1) {
      _label(
        canvas,
        '$count',
        Offset(rect.right, rect.bottom + 10),
        10,
        const Color(0xFFD4DEF0),
      );
    }
  }

  @override
  bool shouldRepaint(_DelayPlot oldDelegate) => true;
}
