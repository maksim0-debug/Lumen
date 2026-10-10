import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_update_info.dart';
import '../../services/app_logger.dart';
import '../state/app_update_notifier.dart';

/// Release details and browser actions, using the application's theme.
class AppUpdateDialog extends ConsumerStatefulWidget {
  final AppUpdateInfo info;
  const AppUpdateDialog({super.key, required this.info});

  static final _openDialogs = Expando<bool>('application update dialogs');

  static Future<void> show(BuildContext context, AppUpdateInfo info) async {
    if (!context.mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (_openDialogs[navigator] == true) return;
    _openDialogs[navigator] = true;
    try {
      await showDialog<void>(
          context: context, builder: (_) => AppUpdateDialog(info: info));
    } finally {
      _openDialogs[navigator] = false;
    }
  }

  @override
  ConsumerState<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends ConsumerState<AppUpdateDialog> {
  bool _busy = false;

  void _close() {
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _runAction(Future<bool> Function() action, String error) async {
    if (_busy) return;
    setState(() => _busy = true);
    var success = false;
    try {
      success = await action();
    } catch (error, stack) {
      AppLogger.w('Application update dialog action failed',
          tag: 'AppUpdateDialog', error: error, stackTrace: stack);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (success) {
      _close();
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notes = info.releaseNotes.trim();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.system_update_rounded, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                    child: Text('Доступне оновлення',
                        style: theme.textTheme.titleLarge)),
                IconButton(
                    tooltip: 'Закрити',
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded)),
              ]),
              const SizedBox(height: 8),
              Text(
                  info.releaseTitle.isEmpty
                      ? 'Lumen v${info.latestVersion}'
                      : info.releaseTitle,
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              LayoutBuilder(builder: (context, constraints) {
                final narrow = constraints.maxWidth <
                    300 * MediaQuery.textScalerOf(context).scale(14) / 14;
                final installed =
                    _version('Встановлено', info.currentVersion, false);
                final available =
                    _version('Нова версія', info.latestVersion, true);
                if (narrow) {
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        installed,
                        const SizedBox(height: 8),
                        available
                      ]);
                }
                return Row(children: [
                  Expanded(child: installed),
                  const SizedBox(width: 12),
                  Expanded(child: available)
                ]);
              }),
              const SizedBox(height: 20),
              Text('Опис випуску:', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                        notes.isNotEmpty
                            ? notes
                            : 'Опис випуску відсутній. Перегляньте зміни на сторінці релізу GitHub.',
                        style: theme.textTheme.bodyMedium),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy
                    ? null
                    : () => _runAction(
                        () => ref
                            .read(appUpdateProvider.notifier)
                            .openReleaseUrl(
                                info.releaseUrl, info.latestVersion),
                        'Не вдалося відкрити посилання у браузері'),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Відкрити реліз на GitHub',
                    textAlign: TextAlign.center),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy
                    ? null
                    : () {
                        ref
                            .read(appUpdateProvider.notifier)
                            .dismissBadge(info.latestVersion);
                        _close();
                      },
                child: const Text('Пізніше'),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy
                    ? null
                    : () => _runAction(
                        () => ref
                            .read(appUpdateProvider.notifier)
                            .ignoreVersion(info.latestVersion),
                        'Не вдалося зберегти вибір. Спробуйте ще раз.'),
                child: const Text('Пропустити цю версію (не нагадувати)',
                    textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _version(String label, String version, bool isNew) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color:
              isNew ? colors.primaryContainer : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.labelMedium?.copyWith(
                color: isNew
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant)),
        const SizedBox(height: 4),
        SelectableText('v$version',
            style: theme.textTheme.titleMedium?.copyWith(
                color: isNew ? colors.onPrimaryContainer : colors.onSurface)),
      ]),
    );
  }
}
