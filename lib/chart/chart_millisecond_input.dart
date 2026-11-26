import 'package:flutter/material.dart';

class ChartMillisecondInput extends StatefulWidget {
  const ChartMillisecondInput({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  State<ChartMillisecondInput> createState() => _ChartMillisecondInputState();
}

class _ChartMillisecondInputState extends State<ChartMillisecondInput> {
  late final _text = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _text.text = '${widget.value}';
    });
  }

  @override
  void didUpdateWidget(ChartMillisecondInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        int.tryParse(_text.text.trim()) != widget.value) {
      _text.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    keyboardType: TextInputType.numberWithOptions(signed: widget.min < 0),
    decoration: InputDecoration(
      isDense: true,
      labelText: widget.label,
      suffixText: 'ms',
    ),
    onChanged: (text) {
      final value = int.tryParse(text.trim());
      if (value != null && value >= widget.min && value <= widget.max) {
        widget.onChanged(value);
      }
    },
  );
}
