import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_perspective.dart';
import 'chart_playback_view.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';

class ChartPlaybackViewEditor extends StatefulWidget {
  const ChartPlaybackViewEditor({
    super.key,
    required this.initial,
    required this.lanes,
    this.skin,
    this.appearance = defaultChartAppearance,
  });

  final ChartPlaybackView initial;
  final ChartLaneMode lanes;
  final ValueListenable<ChartSkin>? skin;
  final ChartAppearance appearance;

  @override
  State<ChartPlaybackViewEditor> createState() =>
      _ChartPlaybackViewEditorState();
}

class _ChartPlaybackViewEditorState extends State<ChartPlaybackViewEditor> {
  static final _sample = ChartTimeline(
    AffChart.parse(
      '${AffChart.blank}'
      '(920,0);(1000,1);(1220,3);(1420,5);hold(1430,1850,4);'
      'arc(1000,1000,0.24,0.24,s,0.92,0.92,0,none,true)[arctap(1000)];'
      'arc(1080,1670,0.78,0.27,sisi,0.55,0.95,1,none,false);'
      'arc(1750,1750,0.84,0.84,s,0.88,0.88,0,none,true)[arctap(1750)];',
    ),
  );

  final _cursor = ValueNotifier(1000.0);
  late final _fields = {
    for (final axis in ChartViewAxis.values)
      axis: TextEditingController(text: axis.value(widget.initial).toString()),
  };
  late var _draft = widget.initial;
  bool _showSettings = true;

  double? _number(ChartViewAxis axis) {
    final value = double.tryParse(_fields[axis]!.text.trim());
    return value?.isFinite == true ? value : null;
  }

  void _readFields() {
    setState(() {
      _draft = (
        width: _number(ChartViewAxis.width) ?? _draft.width,
        length: _number(ChartViewAxis.length) ?? _draft.length,
        pitch: _number(ChartViewAxis.pitch) ?? _draft.pitch,
        height: _number(ChartViewAxis.height) ?? _draft.height,
        runout: _number(ChartViewAxis.runout) ?? _draft.runout,
        skyHeight: _number(ChartViewAxis.skyHeight) ?? _draft.skyHeight,
      );
    });
  }

  void _reset() {
    for (final axis in ChartViewAxis.values) {
      _fields[axis]!.text = axis.value(defaultChartPlaybackView).toString();
    }
    _readFields();
  }

  bool _inputOutsideView(Size size) {
    if (size.isEmpty) return false;
    final geometry = PerspectiveGeometry.forPlayback(
      size,
      _cursor.value,
      2100,
      _sample,
      widget.lanes,
      view: _draft,
    );
    final six = widget.lanes == ChartLaneMode.six;
    final frame = Offset.zero & size;
    return [
      geometry.project(six ? -.125 : .125, 0, geometry.time),
      geometry.project(six ? 1.125 : .875, 0, geometry.time),
      geometry.projectAir(.5, geometry.skyLineHeight, geometry.time),
    ].any((point) => !frame.contains(point));
  }

  @override
  void dispose() {
    _cursor.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder(
          valueListenable:
              widget.skin ?? const AlwaysStoppedAnimation(ChartSkin.defaults),
          builder: (context, skin, _) => CustomPaint(
            painter: ChartPerspectivePainter(
              _sample,
              _cursor,
              2100,
              skin: skin,
              playbackFraming: true,
              playbackView: _draft,
              laneMode: widget.lanes,
              appearance: widget.appearance,
            ),
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const BackButton(),
                    const Text('3D 游玩视角'),
                    IconButton(
                      tooltip: _showSettings ? '收起参数' : '展开参数',
                      onPressed: () =>
                          setState(() => _showSettings = !_showSettings),
                      icon: Icon(
                        _showSettings ? Icons.expand_less : Icons.tune,
                      ),
                    ),
                    TextButton(onPressed: _reset, child: const Text('恢复默认')),
                    TextButton(
                      onPressed:
                          ChartViewAxis.values.any(
                            (axis) => _number(axis) == null,
                          )
                          ? null
                          : () => Navigator.pop(context, _draft),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ),
              if (_showSettings)
                Flexible(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: 6,
                      bottom: math.min(
                        MediaQuery.viewInsetsOf(context).bottom,
                        MediaQuery.sizeOf(context).height * .5,
                      ),
                    ),
                    child: SizedBox(
                      width: 330,
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final axis in ChartViewAxis.values)
                                _control(axis),
                              if (_inputOutsideView(MediaQuery.sizeOf(context)))
                                Text(
                                  '部分判定位置已超出画面',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              const Text(
                                '俯仰角相对设备默认值。轨道高度为画面高度的百分比，正值上移。宽度和长度取绝对值。',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _control(ChartViewAxis axis) {
    final value = axis.value(_draft);
    final outside = value < axis.min || value > axis.max;
    return Column(
      children: [
        TextField(
          key: ValueKey(axis),
          controller: _fields[axis],
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: InputDecoration(
            isDense: true,
            labelText: axis.label,
            suffixText: axis.unit,
            helperText:
                '${outside ? '超出推荐范围 · ' : ''}建议 ${axis.min} 到 ${axis.max} ${axis.unit}',
            errorText: _number(axis) == null ? '请输入有限数值' : null,
          ),
          onChanged: (_) => _readFields(),
        ),
        Slider(
          value: value.clamp(axis.min, axis.max),
          min: axis.min,
          max: axis.max,
          onChanged: (value) {
            _fields[axis]!.text = double.parse(
              value.toStringAsFixed(2),
            ).toString();
            _readFields();
          },
        ),
      ],
    );
  }
}
