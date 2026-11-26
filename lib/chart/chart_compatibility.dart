import 'aff_chart.dart';

enum ChartGameVersion {
  arc4('Arc4 · 旧版'),
  arcExt('ArcExt · 新版');

  const ChartGameVersion(this.label);
  final String label;
}

typedef ChartCompatibilityIssue = ({
  String description,
  String? repair,
  int count,
  int? firstTime,
});

class ChartCompatibility {
  ChartCompatibility(this.chart, this.version) {
    _inspect();
  }

  final AffChart chart;
  final ChartGameVersion version;
  final _issues = <String, ChartCompatibilityIssue>{};
  final _events = <AffEvent, String>{};
  final _groupOptions = <int, String>{};
  final _removeHeaders = <String>{};
  bool _removeComments = false;
  bool _addTiming = false;

  List<ChartCompatibilityIssue> get issues => _issues.values.toList();
  bool get canRepair => issues.any((issue) => issue.repair != null);
  bool get isCompatible => issues.isEmpty;

  static const _easings = {
    's',
    'b',
    'si',
    'so',
    'sisi',
    'siso',
    'sosi',
    'soso',
  };
  static const _arcExtScenes = {'arcahvdistort', 'arcahvdebris'};

  void _report(String description, {String? repair, int? time}) {
    final previous = _issues[description];
    _issues[description] = (
      description: description,
      repair: repair,
      count: (previous?.count ?? 0) + 1,
      firstTime: previous?.firstTime ?? time,
    );
  }

  void _inspect() {
    for (final error in chart.errors) {
      if (chart.errors.length == 1 && error == '缺少主 timing 分组的 BPM 指令') {
        _addTiming = true;
        _report(error, repair: '在主轨补充 120 BPM 初始节拍');
      } else {
        _report(error);
      }
    }
    if (chart.errors.isNotEmpty) return;
    final end = AffChart.headerSeparator(chart.source)!;
    final clean = AffChart.maskComments(chart.source);
    final headers = clean.substring(0, end.start).split(RegExp(r'\r?\n'));
    for (final raw in headers) {
      final line = raw.replaceFirst('\uFEFF', '').trim();
      if (line.isEmpty) continue;
      final key = line.split(':').first.trim();
      switch (key) {
        case 'AudioOffset':
        case 'TimingPointDensityFactor':
          break;
        case 'SustainJudgements':
          _report('包含编辑器专用的持续判定标头', repair: '移除自定义判定点，恢复游戏的自动物量');
          _removeHeaders.add(key);
        case 'GroundPositions':
          _report(
            '包含编辑器专用的地键自由坐标标头',
            repair: version == ChartGameVersion.arc4
                ? '将能匹配的自由坐标转为 Arc4 的小数地键写法，移除此标头'
                : '移除自由坐标，改用 ArcExt 的整数轨道',
          );
          _removeHeaders.add(key);
        default:
          _report('未确认的 AFF 标头 $key', repair: '移除此标头');
          _removeHeaders.add(key);
      }
    }
    if (clean != chart.source) {
      _report('AFF 包含注释', repair: '删除注释，保留指令');
      _removeComments = true;
    }
    for (final group in chart.groups.skip(1)) {
      final attributes = group.attributes.trim();
      final normal = <String>[];
      final unsupported = <String>[];
      for (final item in AffGroupOptions(attributes).tokens) {
        final angle = RegExp(r'^angle([xy])(-?\d+)$').firstMatch(item);
        final degrees = RegExp(
          r'^angle([xy])=(-?\d+(?:\.\d+)?)$',
        ).firstMatch(item);
        if (item == 'noinput' || item == 'fadingholds' || angle != null) {
          normal.add(item);
        } else if (degrees != null &&
            (double.tryParse(degrees[2]!)?.abs() ?? double.infinity) <= 1e6) {
          normal.add(
            'angle${degrees[1]}${(double.parse(degrees[2]!) * 10).round() % 3600}',
          );
        } else {
          unsupported.add(item);
        }
      }
      if (unsupported.isNotEmpty) {
        _report(
          '第 ${group.id} 时间组含未确认的参数 ${unsupported.join('、')}',
          repair: '移除这些时间组参数',
        );
      }
      final canonical = normal.join('_');
      if (unsupported.isEmpty && attributes != canonical) {
        _report('第 ${group.id} 时间组使用非标准参数写法', repair: '改用下划线分隔，角度用十分之一度整数');
      }
      if (attributes != canonical) _groupOptions[group.id] = canonical;
    }
    for (final event in chart.events) {
      _inspectEvent(event);
    }
  }

  void _inspectEvent(AffEvent event) {
    final args = event.arguments.toList();
    var changed = false;
    void report(String reason, String? repair) =>
        _report(reason, repair: repair, time: event.start);
    void remove(String reason, String repair) {
      report(reason, repair);
      _events[event] = '';
    }

    switch (event.kind) {
      case AffKind.other:
        remove('未确认的指令 ${event.command}', '移除此指令及其效果');
        return;
      case AffKind.tap:
      case AffKind.hold:
        final index = event.groundLaneIndex;
        final inline = event.inlineGroundPosition;
        final x = event.groundPosition ?? inline;
        if (x != null) {
          if (version == ChartGameVersion.arc4) {
            if (event.groundPosition == null) return;
            args[index] = x.toStringAsFixed(9);
          } else {
            if (inline != null) {
              report('ArcExt 样本未出现 Arc4 小数地键', '按现有横坐标改为最近的整数轨道，可能改变按键位置');
            }
            args[index] = AffEvent.nearestGroundLane(x).toString();
          }
          changed = args[index] != event.arguments[index];
          break;
        }
        final lane = int.parse(args[index]);
        if (lane < 0 || lane > 5) {
          report('地面轨道编号超出 0–5', '移至最靠近的合法轨道');
          args[index] = lane.clamp(0, 5).toString();
          changed = true;
        }
      case AffKind.timing:
        break;
      case AffKind.flick:
        if (version == ChartGameVersion.arcExt) {
          report('ArcExt 样本未确认支持 flick', '改为原时刻、原位置的普通天键，取消滑动方向');
          _events[event] = _skyTap(
            event.start,
            event.number(1),
            event.number(2),
          );
        }
        return;
      case AffKind.camera:
        if (!AffChart.cameraEasings.contains(args[7])) {
          report('未确认的镜头缓动 ${args[7]}', '改用线性镜头缓动');
          args[7] = 'l';
          changed = true;
        }
      case AffKind.scene:
        final type = args[1];
        if (type == 'enwidenlane') {
          report('扩轨指令使用单数 enwidenlane', '改用两套样本均使用的 enwidenlanes');
          args[1] = 'enwidenlanes';
          changed = true;
        } else if (!AffChart.sceneTypes.contains(type) ||
            (version == ChartGameVersion.arc4 &&
                _arcExtScenes.contains(type))) {
          remove('${version.label} 样本未确认场景指令 $type', '移除此场景指令及其效果');
          return;
        } else if ((type == 'trackhide' || type == 'trackshow') &&
            args.length == 4) {
          report('$type 使用四参数写法', '改用两套样本均使用的两参数指令，移除额外时长和控制参数');
          args.removeRange(2, 4);
          changed = true;
        }
      case AffKind.arc:
        if (version == ChartGameVersion.arc4 && event.variableArcTap) {
          report('Arc4 样本未确认支持宽天键', '保留时刻与中心位置，改成普通天键');
          final center = event.arcPoint(.5);
          if (event.arcTaps.isNotEmpty) {
            report('宽天键另附天键', '把附加天键保留为独立的普通天键');
          }
          if (args.length > 10) {
            report('宽天键含扩展参数', '移除普通天键无需的附加参数');
          }
          _events[event] = [
            _skyTap(event.start, center.x, center.height),
            for (final tap in event.arcTaps)
              _skyTap(tap, event.number(2), event.number(5)),
          ].join(chart.newline);
          return;
        }
        if (args.length > 10 &&
            (version == ChartGameVersion.arc4 || !event.hasSmoothness)) {
          report('弧线含十参数之外的扩展', '恢复标准十参数，移除扩展平滑度或其他附加参数');
          args.removeRange(10, args.length);
          changed = true;
        }
        if (!_easings.contains(args[4])) {
          report('未确认的弧线缓动 ${args[4]}', '改用线性弧线');
          args[4] = 's';
          changed = true;
        }
        if (args[9] != 'true' &&
            args[9] != 'false' &&
            !(args[9] == 'designant' && version == ChartGameVersion.arcExt)) {
          report('弧线类型 ${args[9]} 未获该版本样本确认', '近似为普通天空曲线，取消特殊外观');
          args[9] = 'true';
          changed = true;
        }
        final color = int.parse(args[7]);
        if (color < 0 || color > (version == ChartGameVersion.arc4 ? 2 : 3)) {
          report('弧线颜色编号 $color 未获该版本样本确认', '改用编号 0');
          args[7] = '0';
          changed = true;
        }
    }
    if (changed) {
      final taps = event.arcTaps.isEmpty
          ? ''
          : '[${event.arcTaps.map((time) => 'arctap($time)').join(',')}]';
      _events[event] = '${event.command}(${args.join(',')})$taps;';
    }
  }

  String applyRepairs() {
    if (!canRepair) return chart.source;
    if (_addTiming) {
      final separator = AffChart.headerSeparator(chart.source)!;
      final newline = chart.newline;
      final body = chart.source.substring(separator.end);
      final afterSeparator = body.startsWith(newline)
          ? body.substring(newline.length)
          : body;
      return '${chart.source.substring(0, separator.end)}'
          '${separator[0]!.endsWith('\r') ? '\n' : newline}'
          'timing(0,120,4);$newline$afterSeparator';
    }
    var result = chart.replaceEvents(_events);
    if (_groupOptions.isNotEmpty) {
      for (final group in AffChart.parse(result).groups.reversed) {
        if (_groupOptions[group.id] case final attributes?) {
          result = result.replaceRange(
            group.attributesStart,
            group.attributesStart + group.attributes.length,
            attributes,
          );
        }
      }
    }
    if (_removeComments) result = AffChart.maskComments(result);
    final end = AffChart.headerSeparator(result)!;
    final header = result
        .substring(0, end.start)
        .replaceAllMapped(
          RegExp(r'^[^\r\n]+(?:\r?\n|$)', multiLine: true),
          (match) =>
              _removeHeaders.contains(
                match[0]!.split(':').first.replaceFirst('\uFEFF', '').trim(),
              )
              ? (match[0]!.startsWith('\uFEFF') ? '\uFEFF' : '')
              : match[0]!,
        );
    return header + result.substring(end.start);
  }

  static String _skyTap(int time, double x, double height) {
    final left = x.toStringAsFixed(6);
    final y = height.toStringAsFixed(6);
    return 'arc($time,$time,$left,$left,s,$y,$y,0,none,true)[arctap($time)];';
  }
}
