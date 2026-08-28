import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../services/app_logger.dart';
import '../services/parser_service.dart';

import '../services/backup_service.dart';
import '../services/power_monitor_service.dart';
import '../services/preferences_helper.dart';
import '../services/achievement_service.dart';
import '../services/darkness_theme_service.dart';
import 'logs_page.dart';
import 'manual_schedule_editor.dart';
import 'power_monitor_guide_screen.dart';
import '../services/history_service.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback? onThemeChanged;
  final VoidCallback? onScaleChanged;

  const SettingsPage({super.key, this.onThemeChanged, this.onScaleChanged});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _notify1hBeforeOff = true;
  bool _notify30mBeforeOff = true;
  bool _notify5mBeforeOff = true;
  bool _notify1hBeforeOn = true;
  bool _notify30mBeforeOn = true;
  bool _notifyScheduleChange = true;
  bool _isDarkMode = true;
  bool _animationsEnabled = true;
  bool _launchAtStartup = false;
  bool _isLoading = true;
  bool _enableLogging = true;
  bool _powerMonitorEnabled = false;
  double _uiScale = 1.0;
  List<String> _notificationGroups = [];

  final TextEditingController _customUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      SharedPreferences? prefs;
      try {
        prefs = await PreferencesHelper.getSafeInstance();
      } catch (e) {
        AppLogger.w("Error getting SharedPreferences in _loadSettings: $e",
            tag: 'SettingsPage');
      }

      // If prefs is null, we can't load settings, but we should not crash.
      // We will just use defaults initialized in the fields.

      bool launchOnStart = false;
      if (Platform.isWindows) {
        try {
          launchOnStart = await launchAtStartup.isEnabled();
        } catch (e) {
          AppLogger.e("Error checking launchAtStartup",
              tag: 'SettingsPage', error: e);
        }
      }

      if (!mounted) return;

      setState(() {
        _launchAtStartup = launchOnStart;
        if (prefs != null) {
          _notify1hBeforeOff = prefs.getBool('notify_1h_before_off') ?? true;
          _notify30mBeforeOff = prefs.getBool('notify_30m_before_off') ?? true;
          _notify5mBeforeOff = prefs.getBool('notify_5m_before_off') ?? true;
          _notify1hBeforeOn = prefs.getBool('notify_1h_before_on') ?? true;
          _notify30mBeforeOn = prefs.getBool('notify_30m_before_on') ?? true;
          _notifyScheduleChange =
              prefs.getBool('notify_schedule_change') ?? true;
          _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
          _animationsEnabled = DarknessThemeService().areAnimationsEnabled;
          _enableLogging = prefs.getBool('enable_logging') ?? true;
          _powerMonitorEnabled =
              prefs.getBool('power_monitor_enabled') ?? false;
          _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
          // _autoDarknessTheme removed
          _notificationGroups =
              prefs.getStringList('notification_groups') ?? [];

          if (_notificationGroups.isEmpty) {
            String? currentGroup = prefs.getString('selected_group');
            if (currentGroup != null) {
              _notificationGroups = [currentGroup];
            }
          }

          final customUrl = prefs.getString('custom_power_monitor_url') ?? '';
          _customUrlController.text = customUrl;
        }

        _isLoading = false;
      });
    } catch (e) {
      AppLogger.e("Error loading settings", tag: 'SettingsPage', error: e);
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _customUrlController.dispose();
    super.dispose();
  }

  Future<void> _saveSetting(String key, bool value) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      AppLogger.e("Error saving setting $key", tag: 'SettingsPage', error: e);
    }
  }

  Future<void> _saveGroups() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setStringList('notification_groups', _notificationGroups);
    } catch (e) {
      AppLogger.e("Error saving groups", tag: 'SettingsPage', error: e);
    }
  }

  Future<void> _testAndSaveUrl() async {
    final url = _customUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введіть URL бази даних')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final success = await PowerMonitorService().testAndSetUrl(url);
      if (!mounted) return;

      if (success) {
        bool? clearHistory = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Джерело змінено"),
            content: const Text(
                "Ви успішно змінили джерело даних.\n\nБажаєте очистити локальну історію відключень від старого джерела?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Ні, залишити"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Так, очистити",
                    style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );

        if (clearHistory == true) {
          await HistoryService().clearPowerEvents();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Історію відключень очищено')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('URL успішно збережено')),
            );
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Помилка: Не вдалося отримати JSON з цього URL або база закрита від читання.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Налаштування"),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildSwitchTile(
                    "Темна тема",
                    "Використовувати темне оформлення",
                    _isDarkMode, (val) async {
                  setState(() => _isDarkMode = val);
                  await _saveSetting('is_dark_mode', val);
                  AchievementService().trackThemeToggle();
                  if (widget.onThemeChanged != null) widget.onThemeChanged!();
                }),
                _buildCompactThemeSelector(),
                _buildSwitchTile(
                    "Анімації",
                    "Увімкнути візуальні ефекти та анімації",
                    _animationsEnabled, (val) async {
                  setState(() => _animationsEnabled = val);
                  await DarknessThemeService().setAnimationsEnabled(val);
                  // Trigger theme rebuild if needed, though service likely notifies listeners
                  if (widget.onThemeChanged != null) widget.onThemeChanged!();
                }),
                _buildScaleSelector(),
                if (Platform.isWindows) ...[
                  _buildSwitchTile(
                      "Автозапуск при старті Windows",
                      "Запускати програму автоматично при вході в систему",
                      _launchAtStartup, (val) async {
                    setState(() => _launchAtStartup = val);
                    if (val) {
                      await launchAtStartup.enable();
                    } else {
                      await launchAtStartup.disable();
                    }
                  }),
                ],
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    "Групи для сповіщень",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: ParserService.allGroups.map((group) {
                      final isSelected = _notificationGroups.contains(group);
                      return FilterChip(
                        label: Text(group.replaceAll("GPV", "Група ")),
                        selected: isSelected,
                        onSelected: (val) {
                          setState(() {
                            if (val) {
                              _notificationGroups.add(group);
                            } else {
                              if (_notificationGroups.length > 1) {
                                _notificationGroups.remove(group);
                              }
                            }
                          });
                          _saveGroups();
                        },
                      );
                    }).toList(),
                  ),
                ),
                const Divider(),
                _buildSwitchTile(
                  "За 1 годину до відключення",
                  "Сповіщення, що скоро вимкнуть світло",
                  _notify1hBeforeOff,
                  (val) {
                    setState(() => _notify1hBeforeOff = val);
                    _saveSetting('notify_1h_before_off', val);
                  },
                ),
                _buildSwitchTile(
                  "За 30 хвилин до відключення",
                  "Сповіщення, що скоро вимкнуть світло",
                  _notify30mBeforeOff,
                  (val) {
                    setState(() => _notify30mBeforeOff = val);
                    _saveSetting('notify_30m_before_off', val);
                  },
                ),
                _buildSwitchTile(
                  "За 5 хвилин до відключення",
                  "Сповіщення, що світло вимкнуть прямо зараз",
                  _notify5mBeforeOff,
                  (val) {
                    setState(() => _notify5mBeforeOff = val);
                    _saveSetting('notify_5m_before_off', val);
                  },
                ),
                _buildSwitchTile(
                  "За 1 годину до ввімкнення",
                  "Сповіщення, що скоро світло ввімкнуть",
                  _notify1hBeforeOn,
                  (val) {
                    setState(() => _notify1hBeforeOn = val);
                    _saveSetting('notify_1h_before_on', val);
                  },
                ),
                _buildSwitchTile(
                  "За 30 хвилин до ввімкнення",
                  "Сповіщення, що скоро світло ввімкнуть",
                  _notify30mBeforeOn,
                  (val) {
                    setState(() => _notify30mBeforeOn = val);
                    _saveSetting('notify_30m_before_on', val);
                  },
                ),
                const Divider(),
                _buildSwitchTile(
                  "Зміна графіку",
                  "Сповіщення, якщо кількість годин зі світлом змінилась",
                  _notifyScheduleChange,
                  (val) {
                    setState(() => _notifyScheduleChange = val);
                    _saveSetting('notify_schedule_change', val);
                  },
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    "Моніторинг 220В",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.amber,
                    ),
                  ),
                ),
                _buildSwitchTile(
                  "Реальний моніторинг",
                  "Статус електроенергії через сенсор (Firebase)",
                  _powerMonitorEnabled,
                  (val) async {
                    setState(() => _powerMonitorEnabled = val);
                    await _saveSetting('power_monitor_enabled', val);
                    await PowerMonitorService().setEnabled(val);
                  },
                ),
                if (_powerMonitorEnabled) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customUrlController,
                            decoration: const InputDecoration(
                              labelText: 'URL бази даних Firebase',
                              hintText: 'https://xxx.firebasedatabase.app',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _testAndSaveUrl,
                          child: const Text('Зберегти'),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.help_outline, color: Colors.blue),
                    title:
                        const Text("Як налаштувати свій сенсор? (Інструкція)"),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                    onTap: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PowerMonitorGuideScreen()));
                    },
                  ),
                ],
                const Divider(),
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    title: const Text(
                      "Резервне копіювання (Beta)",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    children: [
                      ListTile(
                        leading: const Icon(Icons.download),
                        title: const Text("Створити резервну копію"),
                        subtitle: const Text("Зберегти базу даних у файл"),
                        onTap: () async {
                          try {
                            setState(() => _isLoading = true);
                            final path = await BackupService().exportDatabase();
                            if (context.mounted) {
                              if (path != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text("Збережено в: $path")));
                              } else {
                                // Share sheet opened, no specific success message needed usually
                              }
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text("Помилка експорту: $e")));
                            }
                          } finally {
                            if (mounted) setState(() => _isLoading = false);
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.upload),
                        title: const Text("Відновити з файлу"),
                        subtitle: const Text("Замінити поточну базу даних"),
                        onTap: () async {
                          // Show confirmation dialog
                          bool? confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                    title: const Text("Відновлення даних"),
                                    content: const Text(
                                        "УВАГА! Всі поточні дані будуть замінені даними з файлу. Це неможливо скасувати.\n\nПродовжити?"),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text("Скасувати")),
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text("Відновити",
                                              style: TextStyle(
                                                  color: Colors.red))),
                                    ],
                                  ));

                          if (confirm != true) return;

                          try {
                            setState(() => _isLoading = true);
                            await BackupService().importDatabase();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Базу даних успішно відновлено! Перезапустіть додаток для оновлення даних.")));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content:
                                          Text("Помилка відновлення: $e")));
                            }
                          } finally {
                            if (mounted) setState(() => _isLoading = false);
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.date_range),
                        title: const Text("Експорт історії за період (JSON)"),
                        subtitle: const Text("Зберегти дані до обраної дати"),
                        onTap: () async {
                          final DateTimeRange? picked =
                              await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2024),
                            lastDate: DateTime.now(),
                            helpText: 'Оберіть період для експорту',
                          );

                          if (picked != null) {
                            try {
                              setState(() => _isLoading = true);
                              final path = await BackupService()
                                  .exportPartialHistory(
                                      picked.start, picked.end);
                              if (context.mounted) {
                                if (path != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text("Збережено в: $path")));
                                }
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Помилка: $e")));
                              }
                            } finally {
                              if (mounted) setState(() => _isLoading = false);
                            }
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.data_object),
                        title: const Text("Імпорт історії з JSON"),
                        subtitle: const Text(
                            "Додати збережені раніше події та графіки"),
                        onTap: () async {
                          try {
                            setState(() => _isLoading = true);
                            final count =
                                await BackupService().importPartialHistory();
                            if (context.mounted && count > 0) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(
                                      "Успішно додано записів: $count. Перезапустіть додаток.")));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text("Помилка імпорту: $e")));
                            }
                          } finally {
                            if (mounted) setState(() => _isLoading = false);
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.edit_calendar),
                        title: const Text("Ручне редагування графіку"),
                        subtitle:
                            const Text("Створити або змінити дані історії"),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                        onTap: () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const ManualScheduleEditor()));
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  title: const Text("Переглянути логи"),
                  subtitle: const Text("Історія роботи фонових завдань"),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () {
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const LogsPage()));
                  },
                ),
                _buildSwitchTile(
                  "Увімкнути логування",
                  "Записувати детальну інформацію про роботу",
                  _enableLogging,
                  (val) {
                    setState(() => _enableLogging = val);
                    _saveSetting('enable_logging', val);
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Widget _buildScaleSelector() {
    return ListTile(
      title: const Text("Масштаб"),
      subtitle: const Text(
        "Розмір елементів інтерфейсу",
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
      trailing: DropdownButton<double>(
        value: _uiScale,
        underline: Container(),
        onChanged: (double? newValue) async {
          if (newValue != null) {
            setState(() => _uiScale = newValue);
            try {
              final prefs = await PreferencesHelper.getSafeInstance();
              await prefs.setDouble('ui_scale', newValue);
            } catch (e) {
              AppLogger.e("Error saving ui_scale",
                  tag: 'SettingsPage', error: e);
            }
            if (widget.onScaleChanged != null) widget.onScaleChanged!();
          }
        },
        items: const [
          DropdownMenuItem(value: 0.50, child: Text("50%")),
          DropdownMenuItem(value: 0.75, child: Text("75%")),
          DropdownMenuItem(value: 0.90, child: Text("90%")),
          DropdownMenuItem(value: 1.00, child: Text("100%")),
          DropdownMenuItem(value: 1.15, child: Text("115%")),
        ],
      ),
    );
  }

  Widget _buildSwitchTile(
      String title, String subtitle, bool value, Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildCompactThemeSelector() {
    final currentMode = DarknessThemeService().mode;

    return ListTile(
      title: const Text("Режим теми"),
      subtitle: Text(_getModeDescription(currentMode),
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      trailing: DropdownButton<String>(
        value: currentMode,
        underline: Container(), // Remove underline
        onChanged: (String? newValue) async {
          if (newValue != null) {
            await DarknessThemeService().setMode(newValue);
            setState(() {});
            if (widget.onThemeChanged != null) widget.onThemeChanged!();
          }
        },
        items: const [
          DropdownMenuItem(
            value: 'off',
            child: Text("Вимкнено"),
          ),
          DropdownMenuItem(
            value: 'auto',
            child: Text("Автоматично"),
          ),
          DropdownMenuItem(
            value: 'solarpunk',
            child: Text("🌿 Solarpunk"),
          ),
          DropdownMenuItem(
            value: 'dieselpunk',
            child: Text("⚙️ Dieselpunk"),
          ),
          DropdownMenuItem(
            value: 'cyberpunk',
            child: Text("🌃 Cyberpunk"),
          ),
          DropdownMenuItem(
            value: 'stalker',
            child: Text("☢️ Stalker"),
          ),
        ],
      ),
    );
  }

  String _getModeDescription(String mode) {
    if (mode == 'off') return "Використовується системна тема";
    if (mode == 'auto') return "Змінюється від часу без світла";
    return "Фіксована тема";
  }
}
