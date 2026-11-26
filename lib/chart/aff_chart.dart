import 'dart:convert';
import 'dart:math' as math;

enum AffKind { tap, hold, arc, flick, timing, camera, scene, other }

typedef AffTimingGroup = ({
  int id,
  String attributes,
  int attributesStart,
  int bodyEnd,
});

class AffGroupOptions {
  AffGroupOptions(String attributes)
    : tokens = attributes
          .toLowerCase()
          .split(RegExp(r'[\s_,]+'))
          .where((token) => token.isNotEmpty)
          .toList();

  static final _angle = RegExp(r'^angle([xy])(=?)(-?\d+(?:\.\d+)?)$');
  final List<String> tokens;
  late final angleX = _readAngle('x');
  late final angleY = _readAngle('y');

  bool get noInput => tokens.contains('noinput');
  bool get fadingHolds => tokens.contains('fadingholds');
  bool get hasUnknown => tokens.any(
    (token) =>
        token != 'noinput' && token != 'fadingholds' && !_angle.hasMatch(token),
  );

  double _readAngle(String axis) {
    for (final token in tokens.reversed) {
      final match = _angle.firstMatch(token);
      if (match == null || match[1] != axis) continue;
      final angle = double.tryParse(match[3]!);
      if (angle != null && angle.isFinite) {
        return (angle / (match[2] == '=' ? 1 : 10)) % 360;
      }
    }
    return 0;
  }
}

class AffEvent {
  AffEvent({
    required this.kind,
    required this.command,
    required this.arguments,
    required this.start,
    required this.end,
    required this.group,
    required this.noInput,
    required this.sourceStart,
    required this.sourceEnd,
    this.arcTaps = const [],
  });

  final AffKind kind;
  final String command;
  final List<String> arguments;
  final int start, end, group, sourceStart, sourceEnd;
  final bool noInput;
  final List<int> arcTaps;
  late final arcTapCounts = _countArcTaps();
  Map<int, int> _countArcTaps() {
    final counts = <int, int>{};
    for (final tap in arcTaps) {
      counts.update(tap, (count) => count + 1, ifAbsent: () => 1);
    }
    return Map.unmodifiable(counts);
  }

  List<int>? _sustainJudgements;
  List<int>? get sustainJudgements => _sustainJudgements;
  double? _groundPosition;
  double? get groundPosition => _groundPosition;
  bool get isGround => kind == AffKind.tap || kind == AffKind.hold;
  bool get isSustain =>
      end > start && (kind == AffKind.hold || kind == AffKind.arc && !trace);

  bool get trace => kind == AffKind.arc && arguments[9] != 'false';
  bool get designant => kind == AffKind.arc && arguments[9] == 'designant';
  bool get variableArcTap =>
      kind == AffKind.arc && !trace && start == end && number(7) == 3;
  bool get isNote => switch (kind) {
    AffKind.tap || AffKind.hold || AffKind.arc || AffKind.flick => true,
    _ => false,
  };
  bool get isAir => kind == AffKind.arc || kind == AffKind.flick;
  int get firstTime => math.min(start, end);
  int get lastTime => math.max(start, end);
  double? get _smoothness =>
      arguments.length == 11 ? double.tryParse(arguments[10]) : null;
  bool get hasSmoothness {
    final value = _smoothness;
    return value != null && value.isFinite && value > 0;
  }

  double get smoothness => hasSmoothness ? _smoothness!.clamp(0.25, 8.0) : 1.0;
  late final _numbers = arguments.map(double.tryParse).toList(growable: false);
  double number(int index) => _numbers[index] ?? double.parse(arguments[index]);
  int get groundLaneIndex => kind == AffKind.tap ? 1 : 2;
  double? get inlineGroundPosition =>
      isGround && arguments[groundLaneIndex].contains('.')
      ? number(groundLaneIndex)
      : null;
  static int nearestGroundLane(double x) => (4 * x + .5).round().clamp(0, 5);
  double get standardLaneX {
    final inline = inlineGroundPosition;
    final lane = inline == null
        ? number(groundLaneIndex)
        : nearestGroundLane(inline);
    return (lane - .5) / 4;
  }

  double get laneX => groundPosition ?? inlineGroundPosition ?? standardLaneX;

  ({double x, double height}) point(double ms) {
    if (kind == AffKind.flick) return (x: number(1), height: number(2));
    final fraction = end == start
        ? 0.0
        : ((ms - start) / (end - start)).clamp(0.0, 1.0);
    return arcPoint(fraction);
  }

  ({double x, double height}) arcPoint(double fraction) {
    final easing = arguments[4];
    double curve(String axis) => switch (axis) {
      'i' => math.sin(fraction * math.pi / 2),
      'o' => 1 - math.cos(fraction * math.pi / 2),
      'b' => fraction * fraction * (3 - 2 * fraction),
      _ => fraction,
    };
    final xAxis = easing.length >= 2 ? easing[1] : easing;
    final yAxis = easing.length == 4
        ? easing[3]
        : easing == 'b'
        ? 'b'
        : 's';
    return (
      x: number(2) + (number(3) - number(2)) * curve(xAxis),
      height: number(5) + (number(6) - number(5)) * curve(yAxis),
    );
  }
}

/// Keeps source spans so an edit changes only the chosen statement.
class AffChart {
  AffChart._(
    this.source,
    this.audioOffset,
    this.events,
    this.errors,
    this.unrendered,
    this.newline,
    this.groups, [
    this.warnings = const [],
    this._unboundGroundPositions = const {},
  ]);

  final String source;
  final int audioOffset;
  final List<AffEvent> events;
  final List<String> errors;
  final List<String> warnings;
  final Map<String, double> _unboundGroundPositions;
  final Set<String> unrendered;
  final String newline;
  final List<AffTimingGroup> groups;

  static const blank = 'AudioOffset:0\n-\ntiming(0,120.00,4.00);\n';
  static final _separator = RegExp(r'^[ \t]*-[ \t]*\r?$', multiLine: true);
  static final _sustainHeader = RegExp(
    r'^SustainJudgements:[^\r\n]*(?:\r?\n|$)',
    multiLine: true,
  );
  static final _groundHeader = RegExp(
    r'^GroundPositions:[^\r\n]*(?:\r?\n|$)',
    multiLine: true,
  );
  static const minGroundX = -3.0;
  static const maxGroundX = 4.0;
  static final _offset = RegExp(
    r'^\uFEFF?[ \t]*AudioOffset[ \t]*:[ \t]*([^\r\n]*)',
    multiLine: true,
  );
  static final _groups = RegExp(r'^timinggroup\s*\(([^()]*)\)\s*\{$');
  static const cameraEasings = {'l', 's', 'qi', 'qo', 'reset'};
  static const sceneTypes = {
    'trackhide',
    'trackshow',
    'trackdisplay',
    'hidegroup',
    'enwidenlanes',
    'enwidenlane',
    'enwidencamera',
    'redline',
    'arcahvdistort',
    'arcahvdebris',
  };
  static final _statement = RegExp(
    r'^([a-zA-Z_]\w*|)\s*\(([^()]*)\)\s*(.*?)\s*;$',
    dotAll: true,
  );
  static final _arcTap = RegExp(r'arctap\s*\(\s*(-?\d+)\s*\)');
  static final _wholeNumber = RegExp(r'^-?\d+$');
  static final _parts = RegExp(r'[^;{}]+[;{]|[};]|[^;{}]+(?=[}]|$)');
  static final _comments = RegExp(r'//[^\r\n]*|/\*[\s\S]*?\*/');

  static String maskComments(String source) => source.replaceAllMapped(
    _comments,
    (match) => match[0]!.replaceAll(RegExp(r'[^\r\n]'), ' '),
  );

  static RegExpMatch? headerSeparator(String source) =>
      _separator.firstMatch(maskComments(source));

  factory AffChart.parse(String source) {
    final errors = <String>[];
    final warnings = <String>[];
    final unrendered = <String>{};
    final events = <AffEvent>[];
    final newline = source.contains('\r\n') ? '\r\n' : '\n';
    final clean = maskComments(source);
    final separator = _separator.firstMatch(clean);
    if (separator == null) {
      return AffChart._(
        source,
        0,
        events,
        ['缺少 AFF 标头分隔行「-」'],
        unrendered,
        newline,
        [(id: 0, attributes: '', attributesStart: 0, bodyEnd: source.length)],
      );
    }
    final header = clean.substring(0, separator.start);
    final offset = _offset.firstMatch(header);
    final audioOffset = int.tryParse(offset?[1]?.trim() ?? '0');
    if (audioOffset == null || audioOffset.abs() > 0x7fffffff) {
      errors.add('AudioOffset 必须是有效的毫秒整数');
    }
    if (_offset.allMatches(header).length > 1) errors.add('AudioOffset 重复');

    final groups =
        <({int id, bool noInput, String attributes, int attributesStart})>[
          (id: 0, noInput: false, attributes: '', attributesStart: 0),
        ];
    final timingGroups = <AffTimingGroup>[
      (id: 0, attributes: '', attributesStart: 0, bodyEnd: source.length),
    ];
    var groupId = 0;
    var line = 1;
    var lineCursor = 0;
    void advanceLine(int position) {
      while (lineCursor < position) {
        if (clean.codeUnitAt(lineCursor++) == 10) line++;
      }
    }

    var cursor = separator.end;
    for (final match in _parts.allMatches(clean, cursor)) {
      if (clean.substring(cursor, match.start).trim().isNotEmpty) {
        advanceLine(cursor);
        errors.add('第 $line 行存在不完整的指令');
      }
      cursor = match.end;
      final raw = match[0]!;
      final text = raw.trim();
      if (text.isEmpty) continue;
      final start = match.start + raw.length - raw.trimLeft().length;
      advanceLine(start);
      if (text == '}') {
        if (groups.length == 1) {
          errors.add('第 $line 行有多余的分组结束符');
        } else {
          final group = groups.removeLast();
          timingGroups.add((
            id: group.id,
            attributes: group.attributes,
            attributesStart: group.attributesStart,
            bodyEnd: start,
          ));
        }
        continue;
      }
      if (text == ';') continue;
      final group = _groups.firstMatch(text);
      if (group != null) {
        final attributes = AffGroupOptions(group[1]!);
        if (attributes.hasUnknown) {
          unrendered.add('timinggroup 属性');
        }
        groups.add((
          id: ++groupId,
          noInput: groups.last.noInput || attributes.noInput,
          attributes: group[1]!,
          attributesStart: start + text.indexOf('(') + 1,
        ));
        continue;
      }
      final statement = _statement.firstMatch(text);
      if (statement == null) {
        errors.add('第 $line 行指令不完整，检查括号和分号');
        continue;
      }
      try {
        final active = groups.last;
        final event = _parseEvent(statement, start, match.end, (
          id: active.id,
          noInput: active.noInput,
        ));
        events.add(event);
        if (event.kind == AffKind.other) unrendered.add(event.command);
        if (event.kind == AffKind.scene &&
            !sceneTypes.contains(event.arguments[1])) {
          unrendered.add('scenecontrol ${event.arguments[1]}');
        }
        if (event.kind == AffKind.camera &&
            !cameraEasings.contains(event.arguments[7])) {
          unrendered.add('camera ${event.arguments[7]}');
        }
        if (event.kind == AffKind.arc &&
            ((event.arguments.length > 10 && !event.hasSmoothness) ||
                event.arcTaps.any(
                  (time) => time < event.firstTime || time > event.lastTime,
                ) ||
                !const {
                  's',
                  'b',
                  'si',
                  'so',
                  'sisi',
                  'siso',
                  'sosi',
                  'soso',
                }.contains(event.arguments[4]) ||
                !const {
                  'true',
                  'false',
                  'designant',
                }.contains(event.arguments[9]))) {
          unrendered.add('arc 扩展参数');
        }
      } on FormatException catch (error) {
        errors.add('第 $line 行 ${error.message}');
      }
    }
    if (clean.substring(cursor).trim().isNotEmpty) {
      advanceLine(cursor);
      errors.add('第 $line 行存在不完整的指令');
    }
    if (groups.length != 1) errors.add('timinggroup 缺少结束符「}」');
    if (!events.any(
      (event) => event.kind == AffKind.timing && event.group == 0,
    )) {
      errors.add('缺少主 timing 分组的 BPM 指令');
    }
    final custom = _sustainHeader.firstMatch(
      source.substring(0, separator.start),
    );
    if (custom != null) {
      try {
        final payload = jsonDecode(
          custom[0]!.substring('SustainJudgements:'.length),
        );
        if (payload is! Map) throw const FormatException();
        final keys = _eventKeys(events.where((event) => event.isSustain));
        if (payload.keys.toSet().difference(keys.values.toSet()).isNotEmpty) {
          warnings.add('部分持续判定点无法匹配原指令，请检查 AFF 标头或重新设置。');
        }
        for (final entry in keys.entries) {
          if (!payload.containsKey(entry.value)) continue;
          final points = payload[entry.value];
          if (points is! List || points.any((point) => point is! int)) {
            throw const FormatException();
          }
          entry.key._sustainJudgements = _validSustainTimes(
            entry.key,
            points.cast<int>(),
          );
          if (entry.key.sustainJudgements!.length < points.toSet().length &&
              !warnings.contains('有持续判定点超出音符时间范围。')) {
            warnings.add('有持续判定点超出音符时间范围。');
          }
        }
      } on FormatException {
        errors.add('SustainJudgements 标头格式无效');
      }
    }
    final unboundGround = <String, double>{};
    final ground = _groundHeader.firstMatch(
      source.substring(0, separator.start),
    );
    if (ground != null) {
      try {
        final payload = jsonDecode(
          ground[0]!.substring('GroundPositions:'.length),
        );
        if (payload is! Map) throw const FormatException();
        final keys = _eventKeys(events.where((event) => event.isGround));
        final matched = keys.values.toSet();
        for (final key in payload.keys.cast<String>()) {
          final x = payload[key];
          if (x is! num || !x.isFinite || x < minGroundX || x > maxGroundX) {
            throw const FormatException();
          }
          if (!matched.contains(key)) unboundGround[key] = x.toDouble();
        }
        if (unboundGround.isNotEmpty) warnings.add('部分自由地键坐标无法匹配原指令。');
        for (final entry in keys.entries) {
          entry.key._groundPosition = (payload[entry.value] as num?)
              ?.toDouble();
        }
      } on FormatException {
        errors.add('GroundPositions 标头格式无效');
      }
    }
    return AffChart._(
      source,
      audioOffset != null && audioOffset.abs() <= 0x7fffffff ? audioOffset : 0,
      List.unmodifiable(events),
      List.unmodifiable(errors),
      Set.unmodifiable(unrendered),
      newline,
      List.unmodifiable(timingGroups..sort((a, b) => a.id.compareTo(b.id))),
      List.unmodifiable(warnings),
      Map.unmodifiable(unboundGround),
    );
  }

  static AffEvent _parseEvent(
    RegExpMatch statement,
    int sourceStart,
    int sourceEnd,
    ({int id, bool noInput}) group,
  ) {
    final command = statement[1]!;
    final arguments = statement[2]!
        .split(',')
        .map((arg) => arg.trim())
        .toList();
    final suffix = statement[3]!;
    final kind = switch (command) {
      '' => AffKind.tap,
      'hold' => AffKind.hold,
      'arc' => AffKind.arc,
      'flick' => AffKind.flick,
      'timing' => AffKind.timing,
      'camera' => AffKind.camera,
      'scenecontrol' => AffKind.scene,
      _ => AffKind.other,
    };
    final arity = switch (kind) {
      AffKind.tap => 2,
      AffKind.hold || AffKind.timing => 3,
      AffKind.arc => 10,
      AffKind.flick => 5,
      AffKind.camera => 9,
      AffKind.scene => arguments.length,
      AffKind.other => arguments.length,
    };
    if ((kind == AffKind.arc
            ? arguments.length < arity
            : arguments.length != arity) ||
        (suffix.isNotEmpty && kind != AffKind.arc && kind != AffKind.other)) {
      throw FormatException('${command.isEmpty ? 'tap' : command} 参数格式错误');
    }
    int? integer(int index) => _wholeNumber.hasMatch(arguments[index])
        ? int.tryParse(arguments[index])
        : null;
    bool numeric(int index, {double limit = 1e12}) {
      final value = double.tryParse(arguments[index]);
      return value != null && value.isFinite && value.abs() <= limit;
    }

    bool ground(int index) =>
        integer(index) != null ||
        RegExp(r'^-?\d+\.\d+$').hasMatch(arguments[index]) &&
            numeric(index, limit: 4);

    final time = integer(0);
    final end = kind == AffKind.hold || kind == AffKind.arc ? integer(1) : time;
    if (kind != AffKind.other &&
        (time == null ||
            end == null ||
            (end < time && (kind != AffKind.arc || arguments[9] == 'false')) ||
            time.abs() > 0x7fffffff ||
            end.abs() > 0x7fffffff)) {
      throw const FormatException('时间参数无效');
    }
    final valid = switch (kind) {
      AffKind.tap => ground(1),
      AffKind.hold => ground(2),
      AffKind.timing => numeric(1) && numeric(2, limit: double.maxFinite),
      AffKind.flick => [1, 2, 3, 4].every(numeric),
      AffKind.camera =>
        [1, 2, 3, 4, 5, 6].every(numeric) &&
            arguments[7].isNotEmpty &&
            integer(8) != null &&
            integer(8)! >= 0 &&
            integer(8)! <= 0x7fffffff,
      AffKind.scene =>
        arguments.length >= 2 &&
            arguments[1].isNotEmpty &&
            (!sceneTypes.contains(arguments[1]) ||
                (arguments[1] == 'trackhide' || arguments[1] == 'trackshow'
                    ? arguments.length == 2 ||
                          (arguments.length == 4 &&
                              numeric(2) &&
                              integer(3) != null)
                    : arguments.length == 4 &&
                          numeric(2) &&
                          integer(3) != null)),
      AffKind.arc =>
        [2, 3, 5, 6].every(numeric) &&
            integer(7) != null &&
            arguments[4].isNotEmpty &&
            arguments[9].isNotEmpty,
      AffKind.other => true,
    };
    if (!valid) throw const FormatException('事件参数无效');
    final arcTaps = <int>[];
    if (kind == AffKind.arc && suffix.isNotEmpty) {
      if (!suffix.startsWith('[') || !suffix.endsWith(']')) {
        throw const FormatException('arctap 列表格式错误');
      }
      final content = suffix.substring(1, suffix.length - 1).trim();
      if (content.isNotEmpty) {
        for (final part in content.split(',')) {
          final token = part.trim();
          final found = _arcTap.matchAsPrefix(token);
          final value = int.tryParse(found?[1] ?? '');
          if (found == null ||
              found.end != token.length ||
              value == null ||
              value.abs() > 0x7fffffff) {
            throw const FormatException('arctap 时间无效');
          }
          arcTaps.add(value);
        }
      }
    }
    return AffEvent(
      kind: kind,
      command: command,
      arguments: List.unmodifiable(arguments),
      start: time ?? 0,
      end: end ?? 0,
      group: group.id,
      noInput: group.noInput,
      sourceStart: sourceStart,
      sourceEnd: sourceEnd,
      arcTaps: List.unmodifiable(arcTaps),
    );
  }

  int get firstTime =>
      events.fold(0, (value, event) => math.min(value, event.firstTime));
  int get lastTime =>
      events.fold(0, (value, event) => math.max(value, event.lastTime));

  static Map<AffEvent, String> _eventKeys(Iterable<AffEvent> events) {
    final groups = <String, List<AffEvent>>{};
    for (final event in events) {
      final signature = jsonEncode([
        event.group,
        event.command,
        event.arguments,
      ]);
      (groups[signature] ??= []).add(event);
    }
    // Including the number of identical statements prevents a raw insertion
    // or deletion from silently transferring settings to another occurrence.
    return {
      for (final group in groups.entries)
        for (var index = 0; index < group.value.length; index++)
          group.value[index]: '${group.key}#$index/${group.value.length}',
    };
  }

  static List<int> _validSustainTimes(AffEvent event, Iterable<int> points) =>
      List.unmodifiable(
        points
            .where((at) => at >= event.start && at <= event.end)
            .toSet()
            .toList()
          ..sort(),
      );

  String _writeAnnotations(
    Map<AffEvent, List<int>> choices,
    Map<AffEvent, double> positions, {
    Map<String, double>? unboundGround,
  }) {
    final end = headerSeparator(source)!.start;
    final header = StringBuffer(
      source
          .substring(0, end)
          .replaceAll(_sustainHeader, '')
          .replaceAll(_groundHeader, ''),
    );
    if (choices.isNotEmpty) {
      final keys = _eventKeys(events.where((event) => event.isSustain));
      header.write(
        'SustainJudgements:${jsonEncode({for (final entry in choices.entries)
          if (keys.containsKey(entry.key)) keys[entry.key]!: _validSustainTimes(entry.key, entry.value)})}$newline',
      );
    }
    final unbound = unboundGround ?? _unboundGroundPositions;
    if (positions.isNotEmpty || unbound.isNotEmpty) {
      final keys = _eventKeys(events.where((event) => event.isGround));
      final payload = {
        ...unbound,
        for (final entry in positions.entries)
          if (keys.containsKey(entry.key) &&
              entry.key.standardLaneX != entry.value)
            keys[entry.key]!: entry.value.clamp(minGroundX, maxGroundX),
      };
      if (payload.isNotEmpty) {
        header.write('GroundPositions:${jsonEncode(payload)}$newline');
      }
    }
    return '$header${source.substring(end)}';
  }

  String withSustainJudgements(Map<AffEvent, List<int>?> updates) {
    final choices = {
      for (final event in events)
        event: ?(updates.containsKey(event)
            ? updates[event]
            : event.sustainJudgements),
    };
    return _writeAnnotations(choices, {
      for (final event in events) event: ?event.groundPosition,
    });
  }

  String replace(AffEvent event, String statement) =>
      replaceEvents({event: statement});

  String replaceEvents(
    Map<AffEvent, String> replacements, {
    Map<AffEvent, double?> groundPositions = const {},
  }) {
    final ordered = replacements.keys.toList()
      ..sort((a, b) => b.sourceStart.compareTo(a.sourceStart));
    var result = source;
    for (final event in ordered) {
      result = result.replaceRange(
        event.sourceStart,
        event.sourceEnd,
        replacements[event]!,
      );
    }
    final configured = events.where(
      (event) =>
          event.sustainJudgements != null ||
          event.groundPosition != null ||
          groundPositions.containsKey(event),
    );
    if (configured.isEmpty || replacements.isEmpty) return result;
    final parsed = AffChart.parse(result);
    if (parsed.errors.isNotEmpty) return result;
    final indexed = {
      for (final event in parsed.events) event.sourceStart: event,
    };
    final choices = <AffEvent, List<int>>{};
    final positions = <AffEvent, double>{};
    final surviving = ordered
        .where((event) => replacements[event]!.trim().isNotEmpty)
        .singleOrNull;
    for (final event in configured) {
      final destination =
          replacements[event]?.trim().isEmpty == true &&
              surviving?.kind == event.kind &&
              surviving?.group == event.group
          ? surviving!
          : event;
      final delta = ordered
          .where((old) => old.sourceStart < destination.sourceStart)
          .fold(
            0,
            (sum, old) =>
                sum +
                replacements[old]!.length -
                (old.sourceEnd - old.sourceStart),
          );
      final start = destination.sourceStart + delta;
      final x = groundPositions.containsKey(event)
          ? groundPositions[event]
          : event.groundPosition;
      if (x != null && destination == event) {
        final next = indexed[start];
        if (next != null &&
            next.kind == event.kind &&
            (next.standardLaneX == event.standardLaneX ||
                groundPositions.containsKey(event))) {
          positions[next] = x;
        }
      }
      final points = event.sustainJudgements;
      if (points == null) continue;
      if (replacements[destination] case final statement?) {
        final candidates = parsed.events
            .where(
              (next) =>
                  next.isSustain &&
                  next.kind == event.kind &&
                  next.sourceStart >= start &&
                  next.sourceEnd <= start + statement.length &&
                  (destination == event ||
                      next.start < event.end && next.end > event.start),
            )
            .toList();
        final shift =
            candidates.length == 1 &&
                destination == event &&
                candidates.single.start - event.start ==
                    candidates.single.end - event.end
            ? candidates.single.start - event.start
            : 0;
        for (final next in candidates) {
          choices.putIfAbsent(next, () => []);
        }
        for (final at in points) {
          final time = at + shift;
          final owner = candidates
              .where((next) => next.start <= time && time <= next.end)
              .firstOrNull;
          if (owner != null) choices[owner]!.add(time);
        }
      } else if (indexed[start] case final unchanged?) {
        choices[unchanged] = points;
      }
    }
    return parsed._writeAnnotations(
      choices,
      positions,
      unboundGround: _unboundGroundPositions,
    );
  }

  String append(String statement) =>
      '$source${source.endsWith('\n') ? '' : newline}$statement$newline';

  String appendToGroup(
    int id,
    String statement, {
    List<List<int>?> sustainJudgements = const [],
    List<double?> groundPositions = const [],
  }) {
    final result = _appendToGroup(id, statement);
    final hasNewChoices =
        sustainJudgements.any((points) => points != null) ||
        groundPositions.any((x) => x != null);
    if (!hasNewChoices &&
        !events.any(
          (event) =>
              event.sustainJudgements != null || event.groundPosition != null,
        )) {
      return result;
    }
    final parsed = AffChart.parse(result);
    if (parsed.errors.isNotEmpty) return result;
    final remaining = <int, List<AffEvent>>{};
    for (final event in parsed.events.where((event) => event.isNote)) {
      (remaining[event.group] ??= []).add(event);
    }
    final seen = <int, int>{};
    final choices = <AffEvent, List<int>>{};
    final positions = <AffEvent, double>{};
    for (final event in events.where((event) => event.isNote)) {
      final next = seen.update(
        event.group,
        (index) => index + 1,
        ifAbsent: () => 1,
      );
      if (event.sustainJudgements case final points?) {
        choices[remaining[event.group]![next - 1]] = points;
      }
      if (event.groundPosition case final x?) {
        positions[remaining[event.group]![next - 1]] = x;
      }
    }
    if (hasNewChoices) {
      final added = (remaining[id] ?? const []).skip(seen[id] ?? 0).toList();
      if (added.length == sustainJudgements.length) {
        for (var i = 0; i < added.length; i++) {
          if (sustainJudgements[i] case final points?) {
            choices[added[i]] = points;
          }
        }
      }
      if (added.length == groundPositions.length) {
        for (var i = 0; i < added.length; i++) {
          if (groundPositions[i] case final x?) positions[added[i]] = x;
        }
      }
    }
    return parsed._writeAnnotations(
      choices,
      positions,
      unboundGround: _unboundGroundPositions,
    );
  }

  String _appendToGroup(int id, String statement) {
    if (id == 0) return append(statement);
    final group = groups.firstWhere((group) => group.id == id);
    final lineStart = source.lastIndexOf('\n', group.bodyEnd - 1) + 1;
    final indent = source.substring(lineStart, group.bodyEnd);
    if (indent.trim().isEmpty) {
      return source.replaceRange(
        lineStart,
        lineStart,
        '$indent    $statement$newline',
      );
    }
    return source.replaceRange(
      group.bodyEnd,
      group.bodyEnd,
      '$newline    $statement$newline',
    );
  }

  String changeGroupAttributes(AffTimingGroup group, String attributes) =>
      source.replaceRange(
        group.attributesStart,
        group.attributesStart + group.attributes.length,
        attributes,
      );

  String changeAudioOffset(int offset) {
    final clean = maskComments(source);
    final separator = _separator.firstMatch(clean)!;
    final match = _offset.firstMatch(clean.substring(0, separator.start));
    if (match != null) {
      final valueStart = match.end - match[1]!.length;
      return source.replaceRange(
        valueStart,
        valueStart + match[1]!.trimRight().length,
        '$offset',
      );
    }
    final headerStart = source.startsWith('\uFEFF') ? 1 : 0;
    return source.replaceRange(
      headerStart,
      headerStart,
      'AudioOffset:$offset$newline',
    );
  }
}
