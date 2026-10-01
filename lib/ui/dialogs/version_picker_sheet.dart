import 'package:flutter/material.dart';

import '../../models/schedule_status.dart';

/// Діалог вибору версії графіка ДТЕК (showModalBottomSheet).
class VersionPickerSheet extends StatelessWidget {
  final List<ScheduleVersion> versions;
  final int selectedVersionIndex;
  final ValueChanged<int> onVersionSelected;

  const VersionPickerSheet({
    super.key,
    required this.versions,
    required this.selectedVersionIndex,
    required this.onVersionSelected,
  });

  static Future<void> show({
    required BuildContext context,
    required List<ScheduleVersion> versions,
    required int selectedVersionIndex,
    required ValueChanged<int> onVersionSelected,
  }) {
    if (versions.isEmpty) return Future.value();

    return showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return VersionPickerSheet(
          versions: versions,
          selectedVersionIndex: selectedVersionIndex,
          onVersionSelected: onVersionSelected,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "Оберіть версію",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: versions.length,
              separatorBuilder: (context, index) => const Divider(),
              itemBuilder: (context, index) {
                final versionIndex = versions.length - 1 - index;
                final version = versions[versionIndex];
                final isSelected = versionIndex == selectedVersionIndex;
                return ListTile(
                  leading: const Icon(Icons.history, color: Colors.orange),
                  title: Text(
                    version.timeString,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("(${version.outageString})"),
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () {
                    onVersionSelected(versionIndex);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
