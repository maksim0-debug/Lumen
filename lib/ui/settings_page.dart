import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../services/parser_service.dart';

import '../services/backup_service.dart';
import '../services/power_monitor_service.dart';
import '../services/preferences_helper.dart';
import 'logs_page.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback? onThemeChanged;

  const SettingsPage({super.key, this.onThemeChanged});

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
  bool _launchAtStartup = false;
  bool _isLoading = true;
  bool _enableLogging = true;
  bool _powerMonitorEnabled = false;
  List<String> _notificationGroups = [];

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
        print("Error getting SharedPreferences in _loadSettings: $e");
      }

      // If prefs is null, we can't load settings, but we should not crash.
      // We will just use defaults initialized in the fields.

      bool launchOnStart = false;
      if (Platform.isWindows) {
        try {
          launchOnStart = await launchAtStartup.isEnabled();
        } catch (e) {
          print("Error checking launchAtStartup: $e");
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
          _enableLogging = prefs.getBool('enable_logging') ?? true;
          _powerMonitorEnabled =
              prefs.getBool('power_monitor_enabled') ?? false;
          _notificationGroups =
              prefs.getStringList('notification_groups') ?? [];

          if (_notificationGroups.isEmpty) {
            String? currentGroup = prefs.getString('selected_group');
            if (currentGroup != null) {
              _notificationGroups = [currentGroup];
            }
          }
        }

        _isLoading = false;
      });
    } catch (e) {
      print("Error loading settings: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveSetting(String key, bool value) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      print("Error saving setting $key: $e");
    }
  }

  Future<void> _saveGroups() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setStringList('notification_groups', _notificationGroups);
    } catch (e) {
      print("Error saving groups: $e");
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
                  if (widget.onThemeChanged != null) widget.onThemeChanged!();
                }),
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
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    "Резервне копіювання (Beta)",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text("Створити резервну копію"),
                  subtitle: const Text("Зберегти базу даних у файл"),
                  onTap: () async {
                    try {
                      setState(() => _isLoading = true);
                      final path = await BackupService().exportDatabase();
                      if (mounted) {
                        if (path != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Збережено в: $path")));
                        } else {
                          // Share sheet opened, no specific success message needed usually
                        }
                      }
                    } catch (e) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Помилка експорту: $e")));
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
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text("Скасувати")),
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text("Відновити",
                                        style: TextStyle(color: Colors.red))),
                              ],
                            ));

                    if (confirm != true) return;

                    try {
                      setState(() => _isLoading = true);
                      await BackupService().importDatabase();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                "Базу даних успішно відновлено! Перезапустіть додаток для оновлення даних.")));
                      }
                    } catch (e) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Помилка відновлення: $e")));
                    } finally {
                      if (mounted) setState(() => _isLoading = false);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.data_object),
                  title: const Text("Імпорт історії з JSON"),
                  subtitle:
                      const Text("Додати графіки з парсера (smart_parser)"),
                  onTap: () async {
                    try {
                      setState(() => _isLoading = true);
                      final count = await BackupService().importHistoryJson();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(
                                "Успішно імпортовано: $count записів. Перезапустіть, щоб побачити зміни.")));
                      }
                    } catch (e) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Помилка імпорту: $e")));
                    } finally {
                      if (mounted) setState(() => _isLoading = false);
                    }
                  },
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

  Widget _buildSwitchTile(
      String title, String subtitle, bool value, Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
    );
  }
}
