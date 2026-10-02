import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/schedule_status.dart';
import '../shortcuts/app_key_activator.dart';

/// Intent to move selection down in version picker.
class _VersionNextIntent extends Intent {
  const _VersionNextIntent();
}

/// Intent to move selection up in version picker.
class _VersionPrevIntent extends Intent {
  const _VersionPrevIntent();
}

/// Intent to confirm selection in version picker.
class _VersionConfirmIntent extends Intent {
  const _VersionConfirmIntent();
}

/// Intent to close version picker.
class _VersionCloseIntent extends Intent {
  const _VersionCloseIntent();
}

/// Діалог вибору версії графіка ДТЕК (showModalBottomSheet) з підтримкою клавіатури.
class VersionPickerSheet extends StatefulWidget {
  final List<ScheduleVersion> versions;
  final int selectedVersionIndex;
  final ValueChanged<int> onVersionSelected;

  const VersionPickerSheet({
    super.key,
    required this.versions,
    required this.selectedVersionIndex,
    required this.onVersionSelected,
  });

  static bool _isOpen = false;

  /// Returns true if the version picker modal bottom sheet is currently open.
  static bool get isOpen => _isOpen;

  @visibleForTesting
  static void resetOpenState() {
    _isOpen = false;
  }

  static Future<void> show({
    required BuildContext context,
    required List<ScheduleVersion> versions,
    required int selectedVersionIndex,
    required ValueChanged<int> onVersionSelected,
  }) async {
    if (versions.isEmpty || _isOpen) return;

    _isOpen = true;
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (BuildContext context) {
          return VersionPickerSheet(
            versions: versions,
            selectedVersionIndex: selectedVersionIndex,
            onVersionSelected: onVersionSelected,
          );
        },
      );
    } finally {
      _isOpen = false;
    }
  }

  @override
  State<VersionPickerSheet> createState() => _VersionPickerSheetState();
}

class _VersionPickerSheetState extends State<VersionPickerSheet> {
  static final Map<ShortcutActivator, Intent> _versionShortcuts = {
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        const _VersionNextIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad2):
        const _VersionNextIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyS,
        physicalKey: PhysicalKeyboardKey.keyS): const _VersionNextIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyJ,
        physicalKey: PhysicalKeyboardKey.keyJ): const _VersionNextIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        const _VersionPrevIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad8):
        const _VersionPrevIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyW,
        physicalKey: PhysicalKeyboardKey.keyW): const _VersionPrevIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyK,
        physicalKey: PhysicalKeyboardKey.keyK): const _VersionPrevIntent(),
    const SingleActivator(LogicalKeyboardKey.enter):
        const _VersionConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const _VersionConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.space):
        const _VersionConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.escape):
        const _VersionCloseIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyV,
        physicalKey: PhysicalKeyboardKey.keyV,
        includeRepeats: false): const _VersionCloseIntent(),
  };

  late int _focusedListIndex;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    if (widget.selectedVersionIndex >= 0 &&
        widget.selectedVersionIndex < widget.versions.length) {
      _focusedListIndex =
          widget.versions.length - 1 - widget.selectedVersionIndex;
    } else {
      _focusedListIndex = 0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToFocusedIndex(animated: false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToFocusedIndex({required bool animated}) {
    if (!_scrollController.hasClients) return;
    const double estimatedItemHeight = 68.0;
    final double targetOffset = (_focusedListIndex * estimatedItemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    if (animated) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(targetOffset);
    }
  }

  void _moveFocus(int delta) {
    if (widget.versions.isEmpty) return;
    final next =
        (_focusedListIndex + delta).clamp(0, widget.versions.length - 1);
    if (next == _focusedListIndex) return;
    setState(() {
      _focusedListIndex = next;
    });
    _scrollToFocusedIndex(animated: true);
  }

  void _confirmSelection() {
    if (_focusedListIndex >= 0 && _focusedListIndex < widget.versions.length) {
      final actualIndex = widget.versions.length - 1 - _focusedListIndex;
      widget.onVersionSelected(actualIndex);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark ? Colors.orange : Colors.deepPurple;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Shortcuts(
      shortcuts: _versionShortcuts,
      child: Actions(
        actions: {
          _VersionNextIntent: CallbackAction<_VersionNextIntent>(
            onInvoke: (_) {
              _moveFocus(1);
              return null;
            },
          ),
          _VersionPrevIntent: CallbackAction<_VersionPrevIntent>(
            onInvoke: (_) {
              _moveFocus(-1);
              return null;
            },
          ),
          _VersionConfirmIntent: CallbackAction<_VersionConfirmIntent>(
            onInvoke: (_) {
              _confirmSelection();
              return null;
            },
          ),
          _VersionCloseIntent: CallbackAction<_VersionCloseIntent>(
            onInvoke: (_) {
              Navigator.pop(context);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screenHeight * 0.75),
              child: Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Оберіть версію",
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            "↑ / ↓ • Enter • Esc",
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white38 : Colors.black38,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView.separated(
                        controller: _scrollController,
                        shrinkWrap: true,
                        itemCount: widget.versions.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final versionIndex =
                              widget.versions.length - 1 - index;
                          final version = widget.versions[versionIndex];
                          final effectiveSelected =
                              widget.selectedVersionIndex >= 0
                                  ? widget.selectedVersionIndex
                                  : widget.versions.length - 1;
                          final isSelected = versionIndex == effectiveSelected;
                          final isFocused = index == _focusedListIndex;

                          return Material(
                            color: isFocused
                                ? accentColor.withValues(alpha: 0.12)
                                : Colors.transparent,
                            child: ListTile(
                              leading: const Icon(Icons.history,
                                  color: Colors.orange),
                              title: Text(
                                version.timeString,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text("(${version.outageString})"),
                              trailing: isSelected
                                  ? const Icon(Icons.check, color: Colors.green)
                                  : (isFocused
                                      ? Icon(Icons.keyboard_return,
                                          size: 18, color: accentColor)
                                      : null),
                              onTap: () {
                                widget.onVersionSelected(versionIndex);
                                Navigator.pop(context);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
