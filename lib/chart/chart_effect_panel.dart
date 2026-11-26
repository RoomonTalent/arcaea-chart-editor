import 'package:flutter/material.dart';

import 'aff_chart.dart';

const _laneTrack = 'enwidenlanes';
const _laneCamera = 'enwidencamera';
const _laneBoth = 'lanesAndCamera';
const _laneTypes = {_laneTrack, 'enwidenlane', _laneCamera};

String _laneLabel(String type) => switch (type) {
  _laneBoth => '轨道与镜头',
  _laneCamera => '镜头',
  _ => '轨道',
};

class ChartEffectPanel extends StatefulWidget {
  const ChartEffectPanel({
    super.key,
    required this.chart,
    required this.initialTime,
    required this.initialGroup,
    required this.onChart,
    this.laneSwitchesOnly = false,
  });

  final AffChart chart;
  final int initialTime, initialGroup;
  final ValueChanged<String> onChart;
  final bool laneSwitchesOnly;

  @override
  State<ChartEffectPanel> createState() => _ChartEffectPanelState();
}

class _ChartEffectPanelState extends State<ChartEffectPanel> {
  late var _chart = widget.chart;
  late var _group = widget.initialGroup;
  String? _error;

  void _apply(String source) {
    final next = AffChart.parse(source);
    if (next.errors.isNotEmpty) {
      setState(() => _error = next.errors.first);
      return;
    }
    widget.onChart(source);
    setState(() {
      _chart = next;
      _error = null;
    });
  }

  Future<void> _edit(
    AffKind kind, {
    AffEvent? event,
    String? initialType,
  }) async {
    final statement = await showDialog<String>(
      context: context,
      builder: (_) => _EffectForm(
        kind,
        widget.initialTime,
        event,
        initialType,
        laneSwitch: widget.laneSwitchesOnly,
      ),
    );
    if (!mounted || statement == null) return;
    _apply(
      event == null
          ? _chart.appendToGroup(
              _group,
              statement.replaceAll('\n', _chart.newline),
            )
          : _chart.replace(event, statement),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        _chart.events
            .where(
              (event) => widget.laneSwitchesOnly
                  ? event.kind == AffKind.scene &&
                        _laneTypes.contains(event.arguments[1])
                  : event.group == _group &&
                        (event.kind == AffKind.camera ||
                            event.kind == AffKind.scene),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    return AlertDialog(
      title: Text(widget.laneSwitchesOnly ? '4K／6K 事件' : '镜头与场景控制'),
      content: SizedBox(
        width: 500,
        height: 380,
        child: CustomScrollView(
          slivers: [
            if (!widget.laneSwitchesOnly)
              SliverToBoxAdapter(
                child: DropdownButtonFormField<int>(
                  initialValue: _group,
                  decoration: const InputDecoration(labelText: '时间组'),
                  items: [
                    for (final group in _chart.groups)
                      DropdownMenuItem(
                        value: group.id,
                        child: Text(group.id == 0 ? '主轨' : '分组 ${group.id}'),
                      ),
                  ],
                  onChanged: (group) => setState(() => _group = group!),
                ),
              ),
            if (widget.laneSwitchesOnly)
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('编辑和预览可在「轨道模式 → 自动」下跟随谱面切换。'),
                    TextButton.icon(
                      onPressed: () =>
                          _edit(AffKind.scene, initialType: _laneBoth),
                      icon: const Icon(Icons.add),
                      label: const Text('添加 4K／6K 切换'),
                    ),
                    if (entries.isEmpty) const Text('还没有切换事件'),
                  ],
                ),
              )
            else
              SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _edit(AffKind.camera),
                      icon: const Icon(Icons.videocam_outlined),
                      label: const Text('添加镜头'),
                    ),
                    TextButton.icon(
                      onPressed: () => _edit(AffKind.scene),
                      icon: const Icon(Icons.layers_outlined),
                      label: const Text('添加场景控制'),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          _edit(AffKind.scene, initialType: _laneTrack),
                      icon: const Icon(Icons.view_week_outlined),
                      label: const Text('添加 4K／6K 切换'),
                    ),
                  ],
                ),
              ),
            if (_error case final error?)
              SliverToBoxAdapter(
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (_, index) {
                final event = entries[index];
                final camera = event.kind == AffKind.camera;
                final lane = widget.laneSwitchesOnly;
                final label = lane
                    ? '${_laneLabel(event.arguments[1])} → ${event.number(3) == 0 ? '4K' : '6K'}'
                    : camera
                    ? '镜头'
                    : event.arguments[1];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${event.start} ms · $label'),
                  subtitle: Text(
                    lane
                        ? '${event.group == 0 ? '主轨' : '分组 ${event.group}'} · 过渡 ${event.arguments[2]} ms'
                        : event.arguments.skip(camera ? 1 : 2).join(', '),
                  ),
                  onTap: () => _edit(event.kind, event: event),
                  trailing: IconButton(
                    onPressed: () => _apply(_chart.replace(event, '')),
                    tooltip: '删除事件',
                    icon: const Icon(Icons.delete_outline),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _EffectForm extends StatefulWidget {
  const _EffectForm(
    this.kind,
    this.initialTime,
    this.event,
    this.initialType, {
    required this.laneSwitch,
  });

  final AffKind kind;
  final int initialTime;
  final AffEvent? event;
  final String? initialType;
  final bool laneSwitch;

  @override
  State<_EffectForm> createState() => _EffectFormState();
}

class _EffectFormState extends State<_EffectForm> {
  final _key = GlobalKey<FormState>();
  bool get _camera => widget.kind == AffKind.camera;
  late final _args =
      widget.event?.arguments.toList() ??
      [
        '${widget.initialTime}',
        if (_camera) ...[
          '0',
          '0',
          '0',
          '0',
          '0',
          '0',
          'l',
          '500',
        ] else ...[
          widget.initialType ?? 'trackhide',
          '0',
          widget.laneSwitch || widget.initialType == _laneTrack ? '1' : '0',
        ],
      ];
  late String _type = _args[_camera ? 7 : 1];
  late int _laneTarget = int.tryParse(_args[3]) == 0 ? 0 : 1;

  Widget _number(
    int index,
    String label, {
    bool integer = false,
    bool nonNegative = false,
  }) {
    return TextFormField(
      key: ValueKey((index, index == 0 || widget.laneSwitch ? '' : _type)),
      initialValue: index < _args.length ? _args[index] : '0',
      decoration: InputDecoration(labelText: label),
      keyboardType: TextInputType.numberWithOptions(
        signed: !nonNegative,
        decimal: !integer,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        final number = integer ? int.tryParse(text) : double.tryParse(text);
        return number == null ||
                !number.isFinite ||
                number.abs() > (integer ? 0x7fffffff : 1e12) ||
                (nonNegative && number < 0)
            ? '请输入有效数字'
            : null;
      },
      onSaved: (value) {
        while (_args.length <= index) {
          _args.add('0');
        }
        _args[index] = value!.trim();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = _camera ? AffChart.cameraEasings : AffChart.sceneTypes;
    final knownType = options.contains(_type);
    final short = !_camera && (_type == 'trackhide' || _type == 'trackshow');
    final seconds = const {
      'redline',
      'arcahvdistort',
      'arcahvdebris',
    }.contains(_type);
    return AlertDialog(
      title: Text(
        widget.laneSwitch
            ? '4K／6K 切换'
            : _camera
            ? '镜头事件'
            : '场景控制事件',
      ),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Form(
          key: _key,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _number(0, '时间（毫秒）', integer: true),
              if (widget.laneSwitch) ...[
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '切换对象'),
                  items: [
                    for (final type
                        in widget.event == null
                            ? [_laneBoth, _laneTrack, _laneCamera]
                            : [_type])
                      DropdownMenuItem(
                        value: type,
                        child: Text(_laneLabel(type)),
                      ),
                  ],
                  onChanged: widget.event == null
                      ? (value) => setState(() => _type = value!)
                      : null,
                ),
                DropdownButtonFormField<int>(
                  initialValue: _laneTarget,
                  decoration: const InputDecoration(labelText: '目标模式'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('4K')),
                    DropdownMenuItem(value: 1, child: Text('6K')),
                  ],
                  onChanged: (value) => setState(() => _laneTarget = value!),
                ),
                _number(2, '过渡时长（毫秒）', nonNegative: true),
              ] else ...[
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: InputDecoration(
                    labelText: _camera ? '缓动' : '事件类型',
                  ),
                  items: [
                    for (final type in {...options, _type})
                      DropdownMenuItem(value: type, child: Text(type)),
                  ],
                  onChanged: (value) => setState(() {
                    _type = value!;
                    if (widget.event == null && _type.startsWith('enwiden')) {
                      _args[3] = '1';
                    }
                  }),
                ),
                if (_camera) ...[
                  for (final (index, label) in [
                    (1, 'X 位移'),
                    (2, 'Y 位移'),
                    (3, 'Z 位移'),
                    (4, '俯仰角'),
                    (5, '偏航角'),
                    (6, '滚转角'),
                  ])
                    _number(index, label),
                  _number(8, '时长（毫秒）', integer: true, nonNegative: true),
                ] else if (knownType && !short) ...[
                  _number(2, '时长（${seconds ? '秒' : '毫秒'}）', nonNegative: true),
                  _number(3, switch (_type) {
                    'hidegroup' => '0 显示，1 隐藏',
                    'enwidenlanes' ||
                    'enwidenlane' ||
                    'enwidencamera' => '0 关闭，1 开启',
                    'redline' => '随机种子',
                    _ => '透明度（0–255）',
                  }, integer: true),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final form = _key.currentState!;
            if (!form.validate()) return;
            form.save();
            if (widget.laneSwitch) {
              final types = _type == _laneBoth
                  ? [_laneTrack, _laneCamera]
                  : [_type];
              Navigator.pop(
                context,
                [
                  for (final type in types)
                    'scenecontrol(${_args[0]},$type,${_args[2]},$_laneTarget);',
                ].join('\n'),
              );
              return;
            }
            _args[_camera ? 7 : 1] = _type;
            final args = _camera || !knownType
                ? _args
                : _args.take(short ? 2 : 4);
            Navigator.pop(
              context,
              '${_camera ? 'camera' : 'scenecontrol'}(${args.join(',')});',
            );
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}
