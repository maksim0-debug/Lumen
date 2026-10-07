import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/schedule_version_preferences.dart';

class ScheduleVersionFilterTile extends ConsumerWidget {
  final bool compact;
  final ValueChanged<bool>? onFocusChange;

  const ScheduleVersionFilterTile({
    super.key,
    this.compact = false,
    this.onFocusChange,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(scheduleVersionPreferencesProvider);
    return SwitchListTile(
      key: const ValueKey('hide-unchanged-schedule-versions'),
      dense: compact,
      onFocusChange: onFocusChange,
      title: const Text('Приховувати версії без змін'),
      subtitle: preference.loadFailed
          ? const Text('Не вдалося прочитати налаштування. '
              'Використано значення за замовчуванням.')
          : compact
              ? null
              : const Text('Приховувати повторні публікації з однаковим '
                  'розкладом вибраної групи'),
      value: preference.hideUnchanged,
      onChanged: !preference.isLoaded || preference.isSaving
          ? null
          : (value) async {
              final saved = await ref
                  .read(scheduleVersionPreferencesProvider.notifier)
                  .setHideUnchanged(value);
              if (!saved && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Не вдалося зберегти налаштування. '
                      'Спробуйте ще раз.'),
                ));
              }
            },
    );
  }
}
