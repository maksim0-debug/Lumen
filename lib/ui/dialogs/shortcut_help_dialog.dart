import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shortcuts/app_intents.dart';
import '../shortcuts/shortcut_registry.dart';

/// Modern HUD dialog displaying all keyboard shortcuts with visual keycap badges.
class ShortcutHelpDialog extends StatelessWidget {
  const ShortcutHelpDialog({super.key});

  static bool _isOpen = false;

  static Future<void> show(BuildContext context) async {
    if (_isOpen) return;
    _isOpen = true;
    try {
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (context) => const ShortcutHelpDialog(),
      );
    } finally {
      _isOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final categories = AppKeyboardShortcuts.cheatSheetCategories;

    final bgColor = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final cardBorder = isDark
        ? Border.all(color: Colors.white.withValues(alpha: 0.12))
        : Border.all(color: Colors.black.withValues(alpha: 0.08));

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape):
            CloseTopModalOrGoBackIntent(),
        SingleActivator(LogicalKeyboardKey.f1): CloseTopModalOrGoBackIntent(),
        SingleActivator(LogicalKeyboardKey.slash, shift: true):
            CloseTopModalOrGoBackIntent(),
        CharacterActivator('?'): CloseTopModalOrGoBackIntent(),
      },
      child: Actions(
        actions: {
          CloseTopModalOrGoBackIntent:
              CallbackAction<CloseTopModalOrGoBackIntent>(
            onInvoke: (intent) {
              Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 680, maxHeight: 720),
                child: Container(
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(20),
                    border: cardBorder,
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: isDark ? 0.6 : 0.2),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // --- Header ---
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color:
                                    (isDark ? Colors.amber : Colors.deepPurple)
                                        .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.keyboard,
                                color:
                                    isDark ? Colors.amber : Colors.deepPurple,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Гарячі клавіші керування',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Швидке керування застосунком без миші',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Закрити (Esc)',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // --- Categories List ---
                      Flexible(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          itemCount: categories.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 18),
                          itemBuilder: (context, index) {
                            final category = categories[index];
                            return _buildCategorySection(
                                context, category, isDark);
                          },
                        ),
                      ),

                      const Divider(height: 1),
                      // --- Footer ---
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  const Icon(Icons.info_outline,
                                      size: 14, color: Colors.grey),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Працює в будь-якій розкладці (EN/UA) • Не блокує введення тексту',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.black45,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Зрозуміло',
                                  style: TextStyle(fontSize: 12)),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategorySection(
    BuildContext context,
    ShortcutCategory category,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              category.icon,
              size: 18,
              color: isDark ? Colors.amber[300] : Colors.deepPurple[400],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                category.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.amber[300] : Colors.deepPurple[700],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.05),
            ),
          ),
          child: Column(
            children: List.generate(category.items.length, (idx) {
              final item = category.items[idx];
              final isLast = idx == category.items.length - 1;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  border: isLast
                      ? null
                      : Border(
                          bottom: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.04)
                                : Colors.black.withValues(alpha: 0.04),
                          ),
                        ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.actionName,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.description,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 5,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          alignment: WrapAlignment.end,
                          children: item.keyLabels.map((keyLabel) {
                            return _buildKeyBadge(keyLabel, isDark);
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyBadge(String keyLabel, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C34) : const Color(0xFFF1F1F5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.black.withValues(alpha: 0.14),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
            offset: const Offset(0, 1.5),
            blurRadius: 1,
          ),
        ],
      ),
      child: Text(
        keyLabel,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
    );
  }
}
