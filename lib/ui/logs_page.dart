import 'package:flutter/material.dart';
import '../../services/history_service.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final logs = await HistoryService().getLogs();
    setState(() {
      _logs = logs;
      _isLoading = false;
    });
  }

  Future<void> _clearLogs() async {
    await HistoryService().clearLogs();
    _loadLogs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Логи"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Очистити логи?"),
                  content: const Text("Це неможливо скасувати."),
                  actions: [
                    TextButton(child: const Text("Ні"), onPressed: () => Navigator.pop(ctx)),
                    TextButton(child: const Text("Так"), onPressed: () {
                      Navigator.pop(ctx);
                      _clearLogs();
                    }),
                  ],
                ),
              );
            },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadLogs),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
            ? Center(child: Text("Пусто", style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  final timestamp = log['timestamp'] as String;
                  final level = log['level'] as String;
                  final message = log['message'] as String;
                  DateTime dt = DateTime.tryParse(timestamp) ?? DateTime.now();
                  
                  // Convert to local time for display
                  dt = dt.toLocal();
                  String timeStr = "${dt.hour}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')} ${dt.day}.${dt.month}";
                  
                  Color? color = Theme.of(context).textTheme.bodyMedium?.color;
                  if (level == 'ERROR') color = Colors.red;
                  
                  return ListTile(
                    dense: true,
                    title: Text(message, style: TextStyle(color: color, fontSize: 13)),
                    subtitle: Text("$timeStr [$level]", style: TextStyle(fontSize: 10)),
                  );
                },
              ),
    );
  }
}
