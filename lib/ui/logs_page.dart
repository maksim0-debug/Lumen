import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/history_service.dart';
import 'dialogs/shortcut_help_dialog.dart';
import 'shortcuts/app_intents.dart';
import 'shortcuts/keyboard_shortcut_wrapper.dart';
import 'shortcuts/shortcut_registry.dart';

enum LogFilterCategory {
  all,
  errors,
  parser,
  powerMonitor,
}

class GroupedLogEntry {
  final String timestamp;
  final String level;
  final String message;
  final int count;

  const GroupedLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.count,
  });
}

List<GroupedLogEntry> groupConsecutiveLogs(List<Map<String, dynamic>> rawLogs) {
  if (rawLogs.isEmpty) return const [];

  final List<GroupedLogEntry> result = [];
  String? currentMessage;
  String? currentLevel;
  String? currentTimestamp;
  int currentCount = 0;

  for (final log in rawLogs) {
    final msg = (log['message'] as String?) ?? '';
    final lvl = (log['level'] as String?) ?? 'INFO';
    final ts = (log['timestamp'] as String?) ?? '';

    if (currentMessage == null) {
      currentMessage = msg;
      currentLevel = lvl;
      currentTimestamp = ts;
      currentCount = 1;
    } else if (currentMessage == msg && currentLevel == lvl) {
      currentCount++;
    } else {
      result.add(GroupedLogEntry(
        timestamp: currentTimestamp!,
        level: currentLevel!,
        message: currentMessage,
        count: currentCount,
      ));
      currentMessage = msg;
      currentLevel = lvl;
      currentTimestamp = ts;
      currentCount = 1;
    }
  }

  if (currentMessage != null) {
    result.add(GroupedLogEntry(
      timestamp: currentTimestamp!,
      level: currentLevel!,
      message: currentMessage,
      count: currentCount,
    ));
  }

  return result;
}

List<GroupedLogEntry> filterGroupedLogs(
  List<GroupedLogEntry> entries,
  LogFilterCategory category,
) {
  switch (category) {
    case LogFilterCategory.all:
      return entries;
    case LogFilterCategory.errors:
      return entries
          .where((e) => e.level == 'ERROR' || e.level == 'WARN')
          .toList();
    case LogFilterCategory.parser:
      return entries.where((e) {
        final msg = e.message.toLowerCase();
        return msg.contains('парсер') || msg.contains('parser');
      }).toList();
    case LogFilterCategory.powerMonitor:
      return entries.where((e) {
        final msg = e.message.toLowerCase();
        return msg.contains('powermonitor') ||
            msg.contains('монітор') ||
            msg.contains('power_monitor');
      }).toList();
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<Map<String, dynamic>> _rawLogs = [];
  bool _isLoading = true;
  LogFilterCategory _selectedCategory = LogFilterCategory.all;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final logs = await HistoryService().getLogs(limit: 300);
    if (!mounted) return;
    setState(() {
      _rawLogs = logs;
      _isLoading = false;
    });
  }

  Future<void> _clearLogs() async {
    await HistoryService().clearLogs();
    if (!mounted) return;
    _loadLogs();
  }

  void _copyLogsToClipboard(List<GroupedLogEntry> entries) {
    if (entries.isEmpty) return;
    final buffer = StringBuffer();
    for (final entry in entries) {
      final multiplier = entry.count > 1 ? " [x${entry.count}]" : "";
      buffer.writeln(
          "[${entry.timestamp}] [${entry.level}]$multiplier ${entry.message}");
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Логи скопійовано в буфер обміну"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = groupConsecutiveLogs(_rawLogs);
    final filtered = filterGroupedLogs(grouped, _selectedCategory);

    final errorCount =
        grouped.where((e) => e.level == 'ERROR' || e.level == 'WARN').length;
    final parserCount = grouped.where((e) {
      final msg = e.message.toLowerCase();
      return msg.contains('парсер') || msg.contains('parser');
    }).length;
    final monitorCount = grouped.where((e) {
      final msg = e.message.toLowerCase();
      return msg.contains('powermonitor') ||
          msg.contains('монітор') ||
          msg.contains('power_monitor');
    }).length;

    return KeyboardShortcutWrapper(
      shortcuts: AppKeyboardShortcuts.logsShortcuts,
      actions: {
        CloseTopModalOrGoBackIntent:
            CallbackAction<CloseTopModalOrGoBackIntent>(
          onInvoke: (intent) {
            Navigator.of(context).maybePop();
            return null;
          },
        ),
        ToggleShortcutHelpIntent: CallbackAction<ToggleShortcutHelpIntent>(
          onInvoke: (intent) {
            ShortcutHelpDialog.show(context);
            return null;
          },
        ),
        RefreshDataIntent: CallbackAction<RefreshDataIntent>(
          onInvoke: (intent) {
            _loadLogs();
            return null;
          },
        ),
        CopyLogsIntent: CallbackAction<CopyLogsIntent>(
          onInvoke: (intent) {
            if (filtered.isNotEmpty) {
              _copyLogsToClipboard(filtered);
            }
            return null;
          },
        ),
        SelectLogFilterCategoryIntent:
            CallbackAction<SelectLogFilterCategoryIntent>(
          onInvoke: (intent) {
            const categories = [
              LogFilterCategory.all,
              LogFilterCategory.errors,
              LogFilterCategory.parser,
              LogFilterCategory.powerMonitor,
            ];
            if (intent.categoryIndex >= 0 &&
                intent.categoryIndex < categories.length) {
              setState(() {
                _selectedCategory = categories[intent.categoryIndex];
              });
            }
            return null;
          },
        ),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Логи"),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: "Оновити (R / F5)",
              onPressed: _loadLogs,
            ),
            IconButton(
              icon: const Icon(Icons.copy_all),
              tooltip: "Скопіювати логи (Ctrl + C)",
              onPressed: filtered.isEmpty
                  ? null
                  : () => _copyLogsToClipboard(filtered),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Очистити",
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Очистити логи?"),
                    content: const Text("Це неможливо скасувати."),
                    actions: [
                      TextButton(
                          child: const Text("Ні"),
                          onPressed: () => Navigator.pop(ctx)),
                      TextButton(
                        child: const Text("Так"),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _clearLogs();
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // Filter chips row
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _buildFilterChip(
                    label: "Всі (${grouped.length}) [1]",
                    category: LogFilterCategory.all,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: "Помилки ($errorCount) [2]",
                    category: LogFilterCategory.errors,
                    isError: true,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: "Парсер ($parserCount) [3]",
                    category: LogFilterCategory.parser,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: "Монітор ($monitorCount) [4]",
                    category: LogFilterCategory.powerMonitor,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                      ? const Center(
                          child: Text("Пусто",
                              style: TextStyle(color: Colors.grey)))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 16),
                          itemBuilder: (context, index) {
                            final log = filtered[index];
                            final timestamp = log.timestamp;
                            final level = log.level;
                            final message = log.message;
                            DateTime dt =
                                DateTime.tryParse(timestamp) ?? DateTime.now();

                            // Convert to local time for display
                            dt = dt.toLocal();
                            String timeStr =
                                "${dt.hour}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} ${dt.day}.${dt.month}";

                            Color? color =
                                Theme.of(context).textTheme.bodyMedium?.color;
                            if (level == 'ERROR') color = Colors.redAccent;
                            if (level == 'WARN') color = Colors.amber;

                            return ListTile(
                              dense: true,
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      message,
                                      style: TextStyle(
                                        color: color,
                                        fontSize: 13,
                                        fontWeight: (level == 'ERROR' ||
                                                level == 'WARN')
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  if (log.count > 1) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: level == 'ERROR'
                                            ? Colors.red.withValues(alpha: 0.2)
                                            : level == 'WARN'
                                                ? Colors.amber
                                                    .withValues(alpha: 0.2)
                                                : Colors.grey
                                                    .withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        "x${log.count}",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: level == 'ERROR'
                                              ? Colors.redAccent
                                              : level == 'WARN'
                                                  ? Colors.amber
                                                  : Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                "$timeStr [$level]",
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required LogFilterCategory category,
    bool isError = false,
  }) {
    final isSelected = _selectedCategory == category;
    return FilterChip(
      selected: isSelected,
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isError && isSelected ? Colors.white : null,
        ),
      ),
      selectedColor: isError ? Colors.redAccent : null,
      onSelected: (_) {
        setState(() {
          _selectedCategory = category;
        });
      },
    );
  }
}
