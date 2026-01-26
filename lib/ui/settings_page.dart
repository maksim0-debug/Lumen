import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../services/parser_service.dart';

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
  List<String> _notificationGroups = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    bool launchOnStart = false;
    if (Platform.isWindows) {
      launchOnStart = await launchAtStartup.isEnabled();
    }

    if (!mounted) return;

    setState(() {
      _launchAtStartup = launchOnStart;
      _notify1hBeforeOff = prefs.getBool('notify_1h_before_off') ?? true;
      _notify30mBeforeOff = prefs.getBool('notify_30m_before_off') ?? true;
      _notify5mBeforeOff = prefs.getBool('notify_5m_before_off') ?? true;
      _notify1hBeforeOn = prefs.getBool('notify_1h_before_on') ?? true;
      _notify30mBeforeOn = prefs.getBool('notify_30m_before_on') ?? true;
      _notifyScheduleChange = prefs.getBool('notify_schedule_change') ?? true;
      _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
      _notificationGroups = prefs.getStringList('notification_groups') ?? [];

      if (_notificationGroups.isEmpty) {
        String? currentGroup = prefs.getString('selected_group');
        if (currentGroup != null) {
          _notificationGroups = [currentGroup];
        }
      }

      _isLoading = false;
    });
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveGroups() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('notification_groups', _notificationGroups);
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
