import 'package:flutter/material.dart';

import 'chart_files.dart';

class ChartBackupDialog extends StatefulWidget {
  const ChartBackupDialog({
    super.key,
    required this.history,
    required this.current,
    this.label,
  });

  final ChartBackupHistory history;
  final String current;
  final String? label;

  @override
  State<ChartBackupDialog> createState() => _ChartBackupDialogState();
}

class _ChartBackupDialogState extends State<ChartBackupDialog> {
  List<ChartBackup> _backups = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(() async {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      final backups = await widget.history.list();
      if (mounted) setState(() => _backups = backups);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(ChartBackup item) => _run(() async {
    final text = await widget.history.read(item);
    if (!mounted) return;
    Navigator.of(context).pop(text);
  });

  Future<void> _delete(ChartBackup item) async {
    if (_busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除此备份？'),
        content: Text(_label(item)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除备份'),
          ),
        ],
      ),
    );
    if (mounted && accepted == true) {
      await _run(() => widget.history.delete(item));
    }
  }

  static String _label(ChartBackup item) {
    final time = item.time.toLocal().toString();
    return item.label == null ? time : '${item.label} · $time';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('谱面备份'),
      content: SizedBox(
        width: 520,
        height: 330,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择备份可载入草稿。载入可撤销，保存后才会写入歌曲目录。'),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: _backups.isEmpty
                  ? Center(child: Text(_busy ? '正在读取备份…' : '还没有备份'))
                  : ListView.builder(
                      itemCount: _backups.length,
                      itemBuilder: (_, index) {
                        final item = _backups[index];
                        return ListTile(
                          title: Text(_label(item)),
                          onTap: _busy ? null : () => _restore(item),
                          trailing: IconButton(
                            tooltip: '删除此备份',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _busy ? null : () => _delete(item),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.tonal(
          onPressed: _busy
              ? null
              : () => _run(
                  () => widget.history.add(widget.current, label: widget.label),
                ),
          child: const Text('备份当前草稿'),
        ),
      ],
    );
  }
}
