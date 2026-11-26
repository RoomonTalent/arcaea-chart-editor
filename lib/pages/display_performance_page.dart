import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DisplayPerformancePage extends StatefulWidget {
  const DisplayPerformancePage({super.key});

  @override
  State<DisplayPerformancePage> createState() => _DisplayPerformancePageState();
}

class _DisplayPerformancePageState extends State<DisplayPerformancePage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('arcaea_manager/display_performance');
  Map<String, Object?>? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) _read();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid && state == AppLifecycleState.resumed) _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _read([Map<String, Object?>? options]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await _channel.invokeMapMethod<String, Object?>(
        options == null ? 'status' : 'configure',
        options,
      );
      if (mounted) setState(() => _status = status);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? '无法读取显示设置');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '当前安装包没有显示性能接口');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final rate = status?['rate'] as int? ?? 0;
    final follow = status?['followGameMode'] == true;
    final currentRate =
        status?['currentRate'] as num? ?? View.of(context).display.refreshRate;
    final votedRate = status?['effectiveRequest'] as num? ?? 0;
    final modes = {
      0,
      -1,
      ...?(status?['rates'] as List?)?.whereType<int>(),
      rate,
    };
    final gameMode = switch (status?['gameMode']) {
      1 => '标准',
      2 => '性能',
      3 => '省电',
      4 => '自定义',
      _ => '设备未报告',
    };
    void update({int? refresh, bool? following}) {
      _read({'rate': refresh ?? rate, 'followGameMode': following ?? follow});
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('显示与触控性能'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              tooltip: '刷新设备状态',
              onPressed: _busy ? null : () => _read(),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error case final error?) ListTile(title: Text(error)),
          ListTile(
            leading: const Icon(Icons.monitor),
            title: const Text('当前显示刷新率'),
            subtitle: Text('${currentRate.toStringAsFixed(1)} Hz'),
          ),
          if (Platform.isAndroid && status != null) ...[
            ListTile(
              title: const Text('全局刷新率请求'),
              subtitle: Text(
                votedRate > 0
                    ? '已请求 ${votedRate.toStringAsFixed(1)} Hz'
                    : '由系统选择',
              ),
              trailing: DropdownButton<int>(
                value: rate,
                onChanged: _busy ? null : (value) => update(refresh: value),
                items: [
                  for (final value in modes)
                    DropdownMenuItem(
                      value: value,
                      child: Text(switch (value) {
                        0 => '自动',
                        -1 => '设备最高',
                        _ => '$value Hz',
                      }),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('自动档跟随系统游戏模式'),
              subtitle: Text('当前模式：$gameMode。性能模式优先最高刷新率，省电模式优先 60 Hz。'),
              value: follow,
              onChanged: _busy ? null : (value) => update(following: value),
            ),
            const ListTile(
              title: Text('低延迟触控请求已启用'),
              subtitle: Text('应用全局请求即时分发触控事件。硬件采样率由设备和系统决定。'),
            ),
          ] else if (!Platform.isAndroid)
            const ListTile(
              title: Text('跟随系统显示设置'),
              subtitle: Text('设备支持时可随系统使用 120 Hz 或更高刷新率。'),
            ),
        ],
      ),
    );
  }
}
