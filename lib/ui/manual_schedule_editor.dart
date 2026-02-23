import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_status.dart';
import '../services/history_service.dart';
import '../services/parser_service.dart';
import '../services/preferences_helper.dart';

class ManualScheduleEditor extends StatefulWidget {
  const ManualScheduleEditor({super.key});

  @override
  State<ManualScheduleEditor> createState() => _ManualScheduleEditorState();
}

class _ManualScheduleEditorState extends State<ManualScheduleEditor> {
  DateTime _selectedDate = DateTime.now();
  String _selectedGroup = 'GPV1.1'; // Default, will update in initState
  List<LightStatus> _schedule = List.filled(24, LightStatus.unknown);
  bool _isLoading = true;
  final TextEditingController _importController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final prefs = await PreferencesHelper.getSafeInstance();
    final savedGroup = prefs.getString('selected_group');
    if (savedGroup != null && ParserService.allGroups.contains(savedGroup)) {
      _selectedGroup = savedGroup;
    } else {
      _selectedGroup = ParserService.allGroups.first;
    }

    await _fetchSchedule();
  }

  Future<void> _fetchSchedule() async {
    setState(() => _isLoading = true);

    try {
      final versions = await HistoryService()
          .getVersionsForDate(_selectedDate, _selectedGroup);

      if (versions.isNotEmpty) {
        // Use the latest version
        final latest = versions.last;
        _schedule = latest.toSchedule().hours;
      } else {
        // No data, default to ON (optimistic default for editing outages)
        _schedule = List.filled(24, LightStatus.on);
      }
    } catch (e) {
      print("Error fetching schedule: $e");
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error loading data: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSchedule() async {
    setState(() => _isLoading = true);
    try {
      final dailySchedule = DailySchedule(_schedule);
      final scheduleCode = dailySchedule.toEncodedString();
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);

      final now = DateTime.now();
      final updateTimeStr =
          "${DateFormat('dd.MM.yyyy HH:mm:ss').format(now)} (Manual)";

      await HistoryService().persistVersion(
        groupKey: _selectedGroup,
        targetDate: dateStr,
        scheduleCode: scheduleCode,
        dtekUpdatedAt: updateTimeStr,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Графік успішно збережено!")),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      print("Error saving schedule: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Помилка збереження: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _cycleStatus(int index) {
    setState(() {
      final current = _schedule[index];
      LightStatus next;
      switch (current) {
        case LightStatus.on:
          next = LightStatus.off;
          break;
        case LightStatus.off:
          next = LightStatus.semiOn;
          break;
        case LightStatus.semiOn:
          next = LightStatus.semiOff;
          break;
        case LightStatus.semiOff:
          next = LightStatus.maybe;
          break;
        case LightStatus.maybe:
          next = LightStatus.on;
          break;
        default:
          next = LightStatus.on;
      }
      _schedule[index] = next;
    });
  }

  void _fillAll(LightStatus status) {
    setState(() {
      for (int i = 0; i < 24; i++) {
        _schedule[i] = status;
      }
    });
  }

  void _parseAndApplyCode(String input) {
    if (input.trim().isEmpty) return;

    try {
      final cleanInput = input.trim();
      List<LightStatus> newSchedule = [];

      if (cleanInput.startsWith('[') && cleanInput.endsWith(']')) {
        // JSON Array format
        final List<dynamic> jsonList = jsonDecode(cleanInput);
        if (jsonList.length != 24) {
          throw Exception("JSON array must have exactly 24 elements");
        }
        newSchedule = jsonList.map((e) => _mapIntToStatus(e)).toList();
      } else {
        // Raw String format
        if (cleanInput.length != 24) {
          throw Exception("Code string must be exactly 24 characters");
        }
        for (int i = 0; i < 24; i++) {
          final char = cleanInput[i];
          final val = int.tryParse(char) ?? 9; // 9 = unknown
          newSchedule.add(_mapIntToStatus(val));
        }
      }

      setState(() {
        _schedule = newSchedule;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Графік успішно імпортовано!")),
      );
      FocusScope.of(context).unfocus(); // Hide keyboard
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Помилка імпорту: $e")),
      );
    }
  }

  LightStatus _mapIntToStatus(dynamic val) {
    int v = 9;
    if (val is int) v = val;
    if (val is String) v = int.tryParse(val) ?? 9;

    switch (v) {
      case 0:
        return LightStatus.on;
      case 1:
        return LightStatus.off;
      case 2:
        return LightStatus.semiOn;
      case 3:
        return LightStatus.semiOff;
      case 4:
        return LightStatus.maybe;
      default:
        return LightStatus.unknown;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Редактор графіку"),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _isLoading ? null : _saveSchedule,
          )
        ],
      ),
      body: Column(
        children: [
          _buildControls(),
          const Divider(),
          _buildImportSection(),
          const Divider(),
          _buildQuickActions(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildGrid(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isLoading ? null : _saveSchedule,
        child: const Icon(Icons.save),
      ),
    );
  }

  Widget _buildImportSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: TextField(
        controller: _importController,
        maxLines: 1,
        decoration: InputDecoration(
          labelText: "Імпорт коду",
          hintText: "Вставте код (напр. 10101... або JSON)",
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          suffixIcon: IconButton(
            icon: const Icon(Icons.download_done, color: Colors.green),
            onPressed: () => _parseAndApplyCode(_importController.text),
            tooltip: "Застосувати",
          ),
        ),
        onChanged: (val) {
          // Optional: debounce auto-apply
          if (val.length == 24 && !val.startsWith('[')) {
            // Verify if all digits
            if (int.tryParse(val) != null) {
              _parseAndApplyCode(val);
            }
          }
        },
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate,
                      firstDate: DateTime(2024),
                      lastDate: DateTime.now()
                          .add(const Duration(days: 1)), // Allow tomorrow too
                    );
                    if (picked != null && picked != _selectedDate) {
                      setState(() {
                        _selectedDate = picked;
                      });
                      _fetchSchedule();
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      DateFormat('EEE, dd MMMM yyyy', 'uk')
                          .format(_selectedDate),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.group, color: Colors.grey),
              const SizedBox(width: 8),
              const Text("Група: ", style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String>(
                  value: _selectedGroup,
                  isExpanded: true,
                  items: ParserService.allGroups.map((g) {
                    return DropdownMenuItem(
                      value: g,
                      child: Text(g.replaceAll("GPV", "Група ")),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null && val != _selectedGroup) {
                      setState(() {
                        _selectedGroup = val;
                      });
                      _fetchSchedule();
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.wb_sunny, color: Colors.amber, size: 18),
            label: const Text("Все є"),
            onPressed: () => _fillAll(LightStatus.on),
          ),
          TextButton.icon(
            icon: Icon(Icons.power_off, color: Colors.grey[800], size: 18),
            label: const Text("Все немає"),
            onPressed: () => _fillAll(LightStatus.off),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 24,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6, // 4 rows of 6 cols = 24 hours
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.0,
      ),
      itemBuilder: (context, index) {
        return _buildCell(index);
      },
    );
  }

  Widget _buildCell(int index) {
    final status = _schedule[index];
    final color = _getColor(status);
    final gradient = _getGradient(status);

    return InkWell(
      onTap: () => _cycleStatus(index),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
            color: gradient == null ? color : null,
            gradient: gradient,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 2,
                offset: const Offset(0, 1),
              )
            ]),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              "$index:00",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color:
                    status == LightStatus.off ? Colors.white70 : Colors.black87,
                fontSize: 12,
              ),
            ),
            Positioned(
              bottom: 2,
              right: 2,
              child: Icon(
                Icons.touch_app,
                size: 10,
                color: (status == LightStatus.off ? Colors.white : Colors.black)
                    .withOpacity(0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getColor(LightStatus status) {
    switch (status) {
      case LightStatus.on:
        return Colors.green[300]!;
      case LightStatus.off:
        return Colors.red[300]!;
      case LightStatus.semiOn:
        return Colors.lightGreen[200]!; // Or yellow-green
      case LightStatus.semiOff:
        return Colors.orange[300]!; // Or yellow-red
      case LightStatus.maybe:
        return Colors.grey[400]!;
      case LightStatus.unknown:
        return Colors.grey[200]!;
      default:
        return Colors.grey[200]!;
    }
  }

  Gradient? _getGradient(LightStatus status) {
    switch (status) {
      case LightStatus.semiOn:
        // First half OFF (Red), Second half ON (Green)
        return const LinearGradient(
          colors: [Color(0xFFEF5350), Color(0xFF66BB6A)], // red400, green400
          stops: [0.5, 0.5],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        );
      case LightStatus.semiOff:
        // First half ON (Green), Second half OFF (Red)
        return const LinearGradient(
          colors: [Color(0xFF66BB6A), Color(0xFFEF5350)],
          stops: [0.5, 0.5],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        );
      default:
        return null;
    }
  }
}
