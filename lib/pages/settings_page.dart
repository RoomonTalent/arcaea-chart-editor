import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chart/chart_appearance.dart';
import '../chart/chart_compatibility.dart';
import '../chart/chart_editor_page.dart';
import '../chart/chart_volume.dart';
import '../models/library_folder.dart';
import '../services/app_state.dart';
import '../services/arc_storage.dart';
import 'catalog_action.dart';
import 'display_performance_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.speed_outlined),
                  title: const Text('显示与触控性能'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DisplayPerformancePage(),
                    ),
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: const Text('铺面音乐音量'),
                  subtitle: const Text('应用于 2D、3D 预览和练习'),
                  onTap: () async {
                    final preferences = await SharedPreferences.getInstance();
                    if (!context.mounted) return;
                    await showChartVolume(
                      context,
                      initial: savedChartVolume(preferences),
                      onChanged: (_) {},
                      preferences: preferences,
                    );
                  },
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.edit_note),
                  title: const Text('谱面编辑器'),
                  subtitle: const Text('新建谱面或打开 AFF 文件'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChartEditorPage(
                        targetVersion: state.hasPath
                            ? state.fileService.storage.isArc4
                                  ? ChartGameVersion.arc4
                                  : ChartGameVersion.arcExt
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.opacity_outlined),
                  title: const Text('谱面不透明度'),
                  subtitle: const Text('天键、蛇、弧线'),
                  onTap: () async {
                    final preferences = await SharedPreferences.getInstance();
                    if (!context.mounted) return;
                    await showChartAppearance(
                      context,
                      initial: savedChartAppearance(preferences),
                      preferences: preferences,
                    );
                  },
                ),
              ),
              _FolderList(state: state),
              const SizedBox(height: 12),

              // 扫描状态
              if (state.hasPath) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline, size: 28),
                            const SizedBox(width: 12),
                            Text(
                              '扫描状态',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (state.isScanning)
                          const Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text('正在扫描...'),
                            ],
                          )
                        else ...[
                          if (state.lastScanTime != null) ...[
                            _InfoRow('上次扫描', _fmtTime(state.lastScanTime)),
                            _InfoRow('数据来源', state.fromCache ? '缓存' : '完整扫描'),
                            _InfoRow('歌曲总数', '${state.songs.length}'),
                            _InfoRow('曲包总数', '${state.packs.length}'),
                            _InfoRow('解锁条目', '${state.unlocks.length}'),
                          ],
                          const SizedBox(height: 12),
                          const Text('在应用外增删谱面或素材后，可用「重新扫描」更新文件索引。'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.refresh),
                                label: const Text('重新扫描'),
                                onPressed: state.isBusy
                                    ? null
                                    : () => state.rescan(),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: state.isBusy
                                    ? null
                                    : () => state.rescan(clearCache: true),
                                child: const Text('清除缓存'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // 关于
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.info, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            '关于',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const _InfoRow('版本', '1.3.9'),
                      const _InfoRow('平台', 'Windows / Android'),
                      const Divider(),
                      const Text(
                        '功能: 管理 Arcaea 曲包、歌曲、铺面文件与解锁信息',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _fmtTime(DateTime? t) {
    if (t == null) return '未知';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

enum _FolderAction { rename, remove }

class _FolderList extends StatelessWidget {
  const _FolderList({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.folder, size: 28),
              title: Text('游戏数据文件夹'),
              subtitle: Text('添加 Arc4 或 ArcExt，可随时切换管理目录。'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('添加文件夹'),
                onPressed: state.isBusy ? null : () => _addFolder(context),
              ),
            ),
            if (state.isScanning && !state.hasPath)
              const LinearProgressIndicator(),
            for (final folder in state.libraries) _folderTile(context, folder),
            if (state.error case final error?)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _folderTile(BuildContext context, LibraryFolder folder) {
    final location = folder.location;
    final active = state.fileService.basePath == location;
    return ListTile(
      key: ValueKey(location),
      selected: active,
      leading: Icon(active ? Icons.check_circle : Icons.folder_outlined),
      title: Text(
        folder.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        active ? '当前使用 · ${folder.displayPath}' : folder.displayPath,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: state.isBusy || active
          ? null
          : () => catalogAction(context, () => state.switchLibrary(location)),
      trailing: PopupMenuButton<_FolderAction>(
        tooltip: '文件夹选项',
        enabled: !state.isBusy,
        onSelected: (action) {
          switch (action) {
            case _FolderAction.rename:
              _renameFolder(context, folder);
            case _FolderAction.remove:
              catalogAction(context, () => state.removeLibrary(location));
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: _FolderAction.rename, child: Text('重命名')),
          PopupMenuItem(value: _FolderAction.remove, child: Text('从列表移除')),
        ],
      ),
    );
  }

  Future<void> _addFolder(BuildContext context) =>
      catalogAction(context, () async {
        final path = await ArcStorage.pick('选择 Arc4 或 ArcExt 文件夹');
        if (path == null) return;
        try {
          final folderName = await ArcStorage.selectedFolderName(path);
          if (!context.mounted) return;
          final folder = LibraryFolder(path, folderName: folderName);
          final name = await _askName(context, folder, adding: true);
          if (name != null && context.mounted) {
            await state.setBasePathAndScan(path, name: name);
          }
        } finally {
          if (!state.libraries.any((folder) => folder.location == path)) {
            await ArcStorage.releaseSelection(path);
          }
        }
      });

  Future<void> _renameFolder(BuildContext context, LibraryFolder folder) async {
    final name = await _askName(context, folder);
    if (name != null && context.mounted) {
      await catalogAction(
        context,
        () => state.renameLibrary(folder.location, name),
      );
    }
  }

  Future<String?> _askName(
    BuildContext context,
    LibraryFolder folder, {
    bool adding = false,
  }) {
    var name = folder.name ?? '';
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(adding ? '添加文件夹' : '重命名文件夹'),
        content: TextFormField(
          autofocus: true,
          initialValue: name,
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.pop(dialog, value),
          decoration: InputDecoration(
            labelText: '显示名称',
            hintText: folder.defaultName,
            helperText: '留空使用文件夹名',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, name),
            child: Text(adding ? '添加' : '保存'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
