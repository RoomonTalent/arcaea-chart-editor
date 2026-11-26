import 'package:flutter/material.dart';

import 'aff_chart.dart';

class ChartTimingPanel extends StatefulWidget {
  const ChartTimingPanel({
    super.key,
    required this.chart,
    required this.initialTime,
    required this.bpmBase,
    required this.onChart,
    required this.onBpmBase,
    this.canSaveBpmBase = false,
  });

  final AffChart chart;
  final int initialTime;
  final double bpmBase;
  final ValueChanged<String> onChart;
  final Future<void> Function(double) onBpmBase;
  final bool canSaveBpmBase;

  @override
  State<ChartTimingPanel> createState() => _ChartTimingPanelState();
}

class _ChartTimingPanelState extends State<ChartTimingPanel> {
  late AffChart _chart = widget.chart;
  late double _bpmBase = widget.bpmBase;
  var _group = 0;
  bool _saving = false;

  Future<void> _edit({AffEvent? event, bool newGroup = false}) async {
    final result = await showDialog<({int time, double bpm, double beats})>(
      context: context,
      builder: (_) => _TimingDialog(
        time: event?.start ?? widget.initialTime,
        bpm: event?.number(1) ?? _bpmBase,
        beats: event?.number(2) ?? 4,
        title: newGroup
            ? '新建变速分组'
            : event == null
            ? '添加变速点'
            : '编辑变速点',
      ),
    );
    if (result == null || !mounted) return;
    final statement = 'timing(${result.time},${result.bpm},${result.beats});';
    final next = newGroup
        ? _chart.append(
            'timinggroup(){${_chart.newline}    $statement${_chart.newline}}',
          )
        : event == null
        ? _chart.appendToGroup(_group, statement)
        : _chart.replace(event, statement);
    if (_apply(next) && newGroup) {
      setState(() => _group = _chart.groups.last.id);
    }
  }

  bool _apply(String source) {
    final chart = AffChart.parse(source);
    if (chart.errors.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(chart.errors.first)));
      return false;
    }
    widget.onChart(source);
    setState(() => _chart = chart);
    return true;
  }

  Future<void> _base() async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) =>
          _BaseBpmDialog(initial: _bpmBase, persistent: widget.canSaveBpmBase),
    );
    if (value == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.onBpmBase(value);
      if (mounted) setState(() => _bpmBase = value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editGroup() async {
    final group = _chart.groups.firstWhere((group) => group.id == _group);
    var attributes = group.attributes;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('时间组属性'),
        content: TextFormField(
          initialValue: attributes,
          onChanged: (value) => attributes = value,
          decoration: const InputDecoration(
            labelText: '属性',
            helperText: '例如 noinput_anglex200、fadingholds',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, attributes.trim()),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (!mounted || result == null || result == group.attributes) return;
    if (result.contains(RegExp(r'[();{}\r\n]'))) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('属性包含无效分隔符')));
      return;
    }
    _apply(_chart.changeGroupAttributes(group, result));
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        _chart.events
            .where(
              (event) => event.kind == AffKind.timing && event.group == _group,
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    return AlertDialog(
      title: const Text('BPM 与谱面流速'),
      content: SizedBox(
        width: 520,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('全谱基准 BPM  $_bpmBase'),
              subtitle: const Text('流速倍率 = 分组 BPM ÷ 基准 BPM'),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _saving ? null : _base,
            ),
            DropdownButtonFormField<int>(
              key: ValueKey(_group),
              initialValue: _group,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '变速分组'),
              items: [
                for (final group in _chart.groups)
                  DropdownMenuItem(
                    value: group.id,
                    child: Text(
                      group.id == 0
                          ? '主轨'
                          : '分组 ${group.id} ${group.attributes}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _group = value!),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('添加变速点'),
                ),
                TextButton(
                  onPressed: () => _edit(newGroup: true),
                  child: const Text('新建分组'),
                ),
                if (_group != 0)
                  TextButton(
                    onPressed: _editGroup,
                    child: const Text('编辑分组属性'),
                  ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final entry = entries[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${entry.start} ms · ${entry.arguments[1]} BPM',
                    ),
                    subtitle: Text(
                      '流速 ${(entry.number(1) / _bpmBase).toStringAsFixed(2)}×',
                    ),
                    onTap: () => _edit(event: entry),
                    trailing: IconButton(
                      tooltip: '删除变速点',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _group == 0 && entries.length == 1
                          ? null
                          : () => _apply(_chart.replace(entry, '')),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _TimingDialog extends StatefulWidget {
  const _TimingDialog({
    required this.title,
    required this.time,
    required this.bpm,
    required this.beats,
  });

  final String title;
  final int time;
  final double bpm, beats;

  @override
  State<_TimingDialog> createState() => _TimingDialogState();
}

class _TimingDialogState extends State<_TimingDialog> {
  final _form = GlobalKey<FormState>();
  late final _time = TextEditingController(text: '${widget.time}');
  late final _bpm = TextEditingController(text: '${widget.bpm}');
  late final _beats = TextEditingController(text: '${widget.beats}');

  @override
  void dispose() {
    _time.dispose();
    _bpm.dispose();
    _beats.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_time, '时间（毫秒）', (value) {
              final time = int.tryParse(value?.trim() ?? '');
              return time == null || time.abs() > 0x7fffffff
                  ? '请输入有效的毫秒整数'
                  : null;
            }, decimal: false),
            _field(_bpm, 'BPM（0 停止，负值倒流）', (value) {
              final bpm = double.tryParse(value?.trim() ?? '');
              return bpm == null || !bpm.isFinite || bpm.abs() > 100000
                  ? '请输入有效的 BPM'
                  : null;
            }),
            _field(_beats, '每小节拍数（0 隐藏节拍线）', (value) {
              final beats = double.tryParse(value?.trim() ?? '');
              return beats == null || !beats.isFinite || beats < 0 || beats > 32
                  ? '请输入 0 到 32'
                  : null;
            }),
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
          if (!_form.currentState!.validate()) return;
          Navigator.pop(context, (
            time: int.parse(_time.text.trim()),
            bpm: double.parse(_bpm.text.trim()),
            beats: double.parse(_beats.text.trim()),
          ));
        },
        child: const Text('应用'),
      ),
    ],
  );
}

class _BaseBpmDialog extends StatefulWidget {
  const _BaseBpmDialog({required this.initial, required this.persistent});

  final double initial;
  final bool persistent;

  @override
  State<_BaseBpmDialog> createState() => _BaseBpmDialogState();
}

class _BaseBpmDialogState extends State<_BaseBpmDialog> {
  final _form = GlobalKey<FormState>();
  late final _value = TextEditingController(text: '${widget.initial}');

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('全谱基准 BPM'),
    content: Form(
      key: _form,
      child: _field(
        _value,
        widget.persistent ? '保存到该难度的 songlist' : '当前编辑会话的基准 BPM',
        (value) {
          final bpm = double.tryParse(value?.trim() ?? '');
          return bpm == null || !bpm.isFinite || bpm < 1 || bpm > 100000
              ? '请输入 1 到 100000'
              : null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, double.parse(_value.text.trim()));
          }
        },
        child: Text(widget.persistent ? '保存' : '应用'),
      ),
    ],
  );
}

Widget _field(
  TextEditingController controller,
  String label,
  FormFieldValidator<String> validator, {
  bool decimal = true,
}) => TextFormField(
  controller: controller,
  keyboardType: TextInputType.numberWithOptions(signed: true, decimal: decimal),
  decoration: InputDecoration(labelText: label),
  validator: validator,
);
