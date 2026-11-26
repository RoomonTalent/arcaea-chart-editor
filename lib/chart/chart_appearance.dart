import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef ChartAppearance = ({double arcTap, double snake, double trace});

const defaultChartAppearance = (arcTap: 1.0, snake: 1.0, trace: 1.0);

const _key = 'chart_opacities';

class ChartAppearanceButton extends StatelessWidget {
  const ChartAppearanceButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '谱面不透明度',
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.opacity_outlined),
      label: const Text('透明度'),
    ),
  );
}

ChartAppearance savedChartAppearance(SharedPreferences? preferences) {
  final values = preferences?.getStringList(_key);
  if (values == null || values.length != 3) return defaultChartAppearance;
  double read(int index) {
    final value = double.tryParse(values[index]);
    return value != null && value.isFinite ? value.clamp(0.0, 1.0) : 1.0;
  }

  return (arcTap: read(0), snake: read(1), trace: read(2));
}

Future<ChartAppearance?> showChartAppearance(
  BuildContext context, {
  required ChartAppearance initial,
  SharedPreferences? preferences,
}) async {
  var draft = initial;
  final selected = await showDialog<ChartAppearance>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, refresh) {
        Widget slider(
          String label,
          double opacity,
          ValueChanged<double> change,
        ) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label · ${(opacity * 100).round()}%'),
            Slider(
              key: ValueKey(label),
              value: opacity,
              label: '${(opacity * 100).round()}%',
              divisions: 20,
              onChanged: (value) => refresh(() => change(value)),
            ),
          ],
        );
        return AlertDialog(
          title: const Text('谱面不透明度'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              slider(
                '天键',
                draft.arcTap,
                (value) => draft = (
                  arcTap: value,
                  snake: draft.snake,
                  trace: draft.trace,
                ),
              ),
              slider(
                '蛇',
                draft.snake,
                (value) => draft = (
                  arcTap: draft.arcTap,
                  snake: value,
                  trace: draft.trace,
                ),
              ),
              slider(
                '弧线',
                draft.trace,
                (value) => draft = (
                  arcTap: draft.arcTap,
                  snake: draft.snake,
                  trace: value,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => refresh(() => draft = defaultChartAppearance),
              child: const Text('恢复默认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, draft),
              child: const Text('应用'),
            ),
          ],
        );
      },
    ),
  );
  if (selected != null && preferences != null) {
    final saved = await preferences.setStringList(_key, [
      selected.arcTap.toString(),
      selected.snake.toString(),
      selected.trace.toString(),
    ]);
    if (!saved && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法保存谱面不透明度偏好')));
    }
  }
  return selected;
}
