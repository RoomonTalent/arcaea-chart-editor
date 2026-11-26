import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const chartMusicVolumeKey = 'chart_music_volume';
const _lastVolumeKey = 'chart_music_volume_before_mute';

double savedChartVolume(SharedPreferences? preferences) {
  final value = preferences?.getDouble(chartMusicVolumeKey) ?? 1;
  return value.isFinite ? value.clamp(0.0, 1.0) : 1;
}

Future<void> showChartVolume(
  BuildContext context, {
  required double initial,
  required ValueChanged<double> onChanged,
  SharedPreferences? preferences,
}) async {
  var gain = initial;
  final previous = preferences?.getDouble(_lastVolumeKey) ?? 1.0;
  var beforeMute = initial == 0
      ? (previous.isFinite ? previous.clamp(0.05, 1.0) : 1.0)
      : initial;
  await showDialog<void>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, refresh) {
        void update(double value) {
          refresh(() {
            gain = value;
            if (gain > 0) beforeMute = gain;
          });
          onChanged(gain);
        }

        return AlertDialog(
          title: const Text('音乐音量'),
          content: Row(
            children: [
              IconButton(
                tooltip: gain == 0 ? '取消静音' : '静音',
                onPressed: () => update(gain == 0 ? beforeMute : 0),
                icon: Icon(gain == 0 ? Icons.volume_off : Icons.volume_up),
              ),
              Expanded(
                child: Slider(
                  value: gain,
                  divisions: 20,
                  label: '${(gain * 100).round()}%',
                  onChanged: update,
                ),
              ),
              Text('${(gain * 100).round()}%'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        );
      },
    ),
  );
  await preferences?.setDouble(_lastVolumeKey, beforeMute);
  await preferences?.setDouble(chartMusicVolumeKey, gain);
}
