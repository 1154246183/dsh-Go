// 备份与还原：把设置打成一个 JSON 存档，随时搬回来。
//
// 只存「设置里的参数」（界面配置、模型与主机配置、预设、技能、App 偏好），
// **不存聊天会话**——会话是内容，不是设置；跟着备份走会让文件越滚越大，
// 也把对话抄到了别处。
//
// 还原只覆盖备份里有的文件，不删任何东西：旧备份还原回来，后来装的技能、
// 新产生的会话都还在。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'backup_service.dart';
import 'settings_widgets.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  /// 备份时是否连 `.credentials.yaml` 一起存。
  ///
  /// 默认关：这个文件装的是各家模型的 key，备份文件一旦被拷走就等于把钥匙
  /// 抄了一份。要用的时候在这儿显式打开。
  bool _withCredentials = false;

  /// 还原时同样要显式允许写回凭据。
  bool _restoreCredentials = false;

  bool _busy = false;
  String _busyLabel = '';

  List<File> _backups = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final list = await listBackups();
    if (!mounted) return;
    setState(() => _backups = list);
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  String _when(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _run(String label, Future<void> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    try {
      await task();
    } catch (error) {
      if (mounted) _toast('$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<void> _create() => _run('正在备份…', () async {
    final result = await createBackup(includeCredentials: _withCredentials);
    HapticFeedback.mediumImpact();
    await _reload();
    if (!mounted) return;
    _toast('已备份 ${result.entries} 个文件 · ${_size(result.bytes)}');
  });

  Future<void> _confirmRestore(File file) async {
    final data = await readBackup(file);
    if (!mounted) return;
    final when = data.at == null ? file.uri.pathSegments.last : _when(data.at!);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('还原这份备份？'),
        content: Text(
          '备份时间：$when\n'
          '文件：${data.files.length} 个'
          '${data.note == null || data.note!.isEmpty ? '' : '\n备注：${data.note}'}\n'
          '${data.credentials ? '\n这份备份里有凭据。' : ''}\n\n'
          '会覆盖同名的设置文件。会话、缓存、后来装的技能都不动。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('还原')),
        ],
      ),
    );
    if (ok != true) return;
    await _run('正在还原…', () async {
      final result = await restoreBackup(file, includeCredentials: _restoreCredentials);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      _toast(
        result.skipped > 0
            ? '已还原 ${result.entries} 个文件，跳过 ${result.skipped} 个'
            : '已还原 ${result.entries} 个文件',
      );
    });
  }

  Future<void> _confirmDelete(File file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这份备份？'),
        content: Text(file.uri.pathSegments.last),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteBackup(file);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return AppPage.list(
      title: '备份与还原',
      subtitle: Text(
        '把设置存成一个文件，换机、重装、试错之后能搬回来。',
        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
      ),
      children: [
        if (_busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(_busyLabel, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
              ],
            ),
          ),
        SettingsSection(
          title: '备份',
          footer: Text(
            '不备份聊天会话。备份文件在 App 的 Documents/backups 下，'
            '用 Filza 或「文件」App 都能拷出来。',
            style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
          ),
          children: [
            SettingsTile(
              icon: AppIcons.download,
              title: '立即备份',
              subtitle: '界面、模型与主机配置、预设、技能、App 偏好',
              onTap: _busy ? null : () => unawaited(_create()),
            ),
            SettingsTile(
              icon: AppIcons.lock,
              title: '连凭据一起备份',
              subtitle: _withCredentials
                  ? '会把各家的 API key 写进备份文件，别把这个文件传到别处'
                  : '关着：.credentials.yaml 不进备份',
              trailing: Switch(
                value: _withCredentials,
                onChanged: _busy ? null : (v) => setState(() => _withCredentials = v),
              ),
              onTap: null,
            ),
          ],
        ),
        SettingsSection(
          title: '还原',
          children: [
            SettingsTile(
              icon: AppIcons.lock,
              title: '还原时写回凭据',
              subtitle: _restoreCredentials ? '会覆盖当前的 .credentials.yaml' : '关着：跳过备份里的凭据',
              trailing: Switch(
                value: _restoreCredentials,
                onChanged: _busy ? null : (v) => setState(() => _restoreCredentials = v),
              ),
              onTap: null,
            ),
          ],
        ),
        SettingsSection(
          title: '已有备份',
          children: [
            if (_backups.isEmpty)
              SettingsTile(
                icon: AppIcons.archive,
                title: '还没有备份',
                subtitle: '点上面的「立即备份」生成第一份',
                onTap: null,
              )
            else
              for (final file in _backups)
                _BackupTile(
                  file: file,
                  size: _size(file.lengthSync()),
                  busy: _busy,
                  onRestore: () => unawaited(_confirmRestore(file)),
                  onDelete: () => unawaited(_confirmDelete(file)),
                ),
          ],
        ),
      ],
    );
  }
}

/// 一份已有备份：名字 + 大小，右边两个动作（还原 / 删除）。
class _BackupTile extends StatelessWidget {
  const _BackupTile({
    required this.file,
    required this.size,
    required this.busy,
    required this.onRestore,
    required this.onDelete,
  });

  final File file;
  final String size;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final name = file.uri.pathSegments.last.replaceAll('.json', '');
    return SettingsTile(
      icon: AppIcons.archive,
      title: name,
      subtitle: size,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: busy ? null : onRestore,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('还原'),
          ),
          IconButton(
            onPressed: busy ? null : onDelete,
            icon: Icon(AppIcons.delete, size: 18, color: dsh.danger),
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      onTap: null,
    );
  }
}
