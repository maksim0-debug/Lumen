import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_logger.dart';
import '../../services/windows_startup_service.dart';
import 'settings_card.dart';

class WindowsStartupSettings extends StatefulWidget {
  const WindowsStartupSettings({super.key, this.service});

  final WindowsStartupService? service;

  @override
  State<WindowsStartupSettings> createState() => _WindowsStartupSettingsState();
}

class _WindowsStartupSettingsState extends State<WindowsStartupSettings> {
  late final _service = widget.service ?? WindowsStartupService.instance;
  bool _enabled = false;
  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  String? _error;
  WindowsStartupMode _mode = WindowsStartupMode.tray;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loaded = false;
      _error = null;
    });
    try {
      final mode = await _service.readMode();
      final enabled = await _service.isEnabled();
      if (!mounted) return;
      setState(() {
        _mode = mode;
        _enabled = enabled;
        _loaded = true;
      });
    } catch (error, stack) {
      _reportError(error, stack);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(Future<void> Function() operation) async {
    if (_saving || _loading) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error, stack) {
      _reportError(error, stack);
      try {
        final enabled = await _service.isEnabled();
        final mode = await _service.readMode();
        if (mounted) {
          setState(() {
            _enabled = enabled;
            _mode = mode;
          });
        }
      } catch (reloadError) {
        AppLogger.w('Cannot refresh Windows startup after failed update',
            tag: 'WindowsStartup', error: reloadError);
        if (mounted) setState(() => _loaded = false);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reportError(Object error, StackTrace stack) {
    AppLogger.e('Cannot read or update Windows startup settings',
        tag: 'WindowsStartup', error: error, stackTrace: stack);
    if (!mounted) return;
    setState(() {
      _error = error is PlatformException &&
              error.code == 'startup_disabled_by_user'
          ? 'Автозапуск вимкнено у Windows. Увімкніть Lumen у Налаштуваннях Windows → Програми → Автозавантаження.'
          : error is PlatformException &&
                  error.code == 'startup_disabled_by_policy'
              ? 'Автозапуск заборонено політикою Windows.'
              : 'Не вдалося застосувати налаштування автозапуску. Спробуйте ще раз.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _saving;
    const titleStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final subtitleStyle = TextStyle(
        fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SettingsCard(
      key: const ValueKey('card_launch'),
      title: 'Запуск застосунку',
      icon: Icons.power_settings_new,
      collapsible: false,
      children: [
        if (busy) const LinearProgressIndicator(),
        SwitchListTile(
          title: const Text('Автозапуск разом із Windows', style: titleStyle),
          subtitle: Text('Автоматично запускати під час входу в систему',
              style: subtitleStyle),
          value: _enabled,
          onChanged: busy || !_loaded
              ? null
              : (value) => _save(() async {
                    await _service.setEnabled(value);
                    if (mounted) setState(() => _enabled = value);
                  }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Режим автозапуску. Запуск ярликом завжди відкриває вікно.',
            style: subtitleStyle,
          ),
        ),
        RadioGroup<WindowsStartupMode>(
          groupValue: _mode,
          onChanged: (value) {
            if (value == null ||
                !_loaded ||
                !_enabled ||
                busy ||
                value == _mode) {
              return;
            }
            _save(() async {
              await _service.writeMode(value);
              if (mounted) setState(() => _mode = value);
            });
          },
          child: Column(children: [
            RadioListTile<WindowsStartupMode>(
              value: WindowsStartupMode.tray,
              enabled: _loaded && _enabled && !busy,
              title: const Text('У треї', style: titleStyle),
              subtitle: Text('Без вікна та кнопки на панелі завдань',
                  style: subtitleStyle),
            ),
            RadioListTile<WindowsStartupMode>(
              value: WindowsStartupMode.minimized,
              enabled: _loaded && _enabled && !busy,
              title:
                  const Text('Згорнуто на панелі завдань', style: titleStyle),
              subtitle: Text('Кнопка застосунку залишається на панелі завдань',
                  style: subtitleStyle),
            ),
          ]),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(
              liveRegion: true,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    TextButton(
                        onPressed: busy ? null : _load,
                        child: const Text('Перевірити ще раз')),
                  ]),
            ),
          ),
      ],
    );
  }
}
