import 'package:flutter/material.dart';

import '../platform/update_service.dart';
import '../platform/updater_download_service.dart';

/// Independent state avoids coupling the updater to appearance/app lifecycle.
class UpdateDownloadPanel extends StatefulWidget {
  const UpdateDownloadPanel({
    super.key,
    required this.updates,
    this.onOpenInBrowser,
  });
  final UpdateService updates;

  /// Optional handoff to the system browser for the release download URL.
  /// When provided, a secondary "在浏览器下载" button is shown so users can
  /// fall back to the system downloader if the in-app stream stalls.
  final Future<void> Function(Uri url)? onOpenInBrowser;

  @override
  State<UpdateDownloadPanel> createState() => _UpdateDownloadPanelState();
}

class _UpdateDownloadPanelState extends State<UpdateDownloadPanel> {
  final download = UpdaterDownloadService();
  @override
  void dispose() {
    download.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装更新'),
        content: const Text(
          '将打开系统安装确认或 Windows 安装向导，不会静默安装、卸载或清除学习数据。'
          'Windows 若提示文件占用，请保存后退出词栖，包括托盘。建议先导出完整备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('打开安装程序'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await download.install();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.updates, download]),
    builder: (context, _) {
      final result = widget.updates.lastResult;
      final metadata = result?.state == UpdateState.available
          ? result?.metadata
          : null;
      if (metadata == null && download.status.isEmpty) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (metadata != null)
            Text('新版 ${metadata.version} · ${metadata.downloadUrl.host}'),
          if (download.status.isNotEmpty) Text(download.status),
          if (download.busy && download.installer == null) ...[
            LinearProgressIndicator(
              value: download.total == null
                  ? null
                  : download.received / download.total!,
            ),
            Text(
              '${(download.received / 1048576).toStringAsFixed(1)} MB'
              '${download.total == null ? '' : ' / ${(download.total! / 1048576).toStringAsFixed(1)} MB'}',
            ),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (metadata != null)
                OutlinedButton(
                  onPressed: download.busy
                      ? null
                      : () => download.download(metadata),
                  child: const Text('下载更新'),
                ),
              if (metadata != null && widget.onOpenInBrowser != null)
                OutlinedButton.icon(
                  onPressed: download.busy && download.installer == null
                      ? null
                      : () => widget.onOpenInBrowser!(metadata.downloadUrl),
                  icon: const Icon(Icons.open_in_browser_outlined, size: 18),
                  label: const Text('在浏览器下载'),
                ),
              if (download.busy && download.installer == null)
                TextButton(
                  onPressed: download.cancel,
                  child: const Text('取消下载'),
                ),
              if (download.installer != null)
                FilledButton(
                  onPressed: download.busy ? null : _install,
                  child: const Text('安装已下载更新'),
                ),
            ],
          ),
          if (metadata != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '应用内下载偶发不稳定时，可改用「在浏览器下载」交给系统下载器；下载完成后从浏览器或通知栏安装即可。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
        ],
      );
    },
  );
}
