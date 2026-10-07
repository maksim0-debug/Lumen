import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/schedule_status.dart';
import '../../services/schedule_version_filter.dart';
import '../shortcuts/app_key_activator.dart';
import '../state/schedule_version_preferences.dart';
import '../widgets/schedule_version_filter_tile.dart';

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
class VersionPickerSheet extends ConsumerStatefulWidget {
  final List<ScheduleVersion> versions;
  final int selectedVersionIndex;
  final ValueChanged<int> onVersionSelected;
  final String? contextLabel;

  const VersionPickerSheet({
    super.key,
    required this.versions,
    required this.selectedVersionIndex,
    required this.onVersionSelected,
    this.contextLabel,
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
    WidgetBuilder? contentBuilder,
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
          return contentBuilder?.call(context) ??
              VersionPickerSheet(
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
  ConsumerState<VersionPickerSheet> createState() => _VersionPickerSheetState();
}

class _VersionPickerSheetState extends ConsumerState<VersionPickerSheet> {
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

  int _focusedListIndex = 0;
  ScheduleVersion? _focusedVersion;
  List<ScheduleVersion>? _projectedVersions;
  bool? _projectedHideUnchanged;
  late ScheduleVersionProjection _projection;
  bool _filterHasFocus = false;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _focusedVersion = _selectedVersion;
  }

  ScheduleVersion? get _selectedVersion => widget.versions.isEmpty
      ? null
      : widget.versions[widget.selectedVersionIndex >= 0 &&
              widget.selectedVersionIndex < widget.versions.length
          ? widget.selectedVersionIndex
          : widget.versions.length - 1];

  void _updateProjection(bool hideUnchanged) {
    if (identical(_projectedVersions, widget.versions) &&
        _projectedHideUnchanged == hideUnchanged) {
      return;
    }
    _projectedVersions = widget.versions;
    _projectedHideUnchanged = hideUnchanged;
    _projection = ScheduleVersionFilter.project(widget.versions,
        hideUnchanged: hideUnchanged);
    var index = _focusedVersion == null
        ? -1
        : widget.versions.indexWhere(_focusedVersion!.isSamePublication);
    if (index < 0) {
      index = _selectedVersion == null
          ? -1
          : widget.versions.indexOf(_selectedVersion!);
    }
    index = _projection.representativeFor(index);
    _focusedVersion = index >= 0 ? widget.versions[index] : null;
    final position = _projection.visibleIndices.indexOf(index);
    _focusedListIndex =
        position >= 0 ? _projection.visibleIndices.length - 1 - position : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFocusedIndex(animated: false);
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
    if (_projection.visibleIndices.isEmpty) return;
    final next = (_focusedListIndex + delta)
        .clamp(0, _projection.visibleIndices.length - 1);
    if (next == _focusedListIndex) return;
    setState(() {
      _focusedListIndex = next;
      final index = _projection
          .visibleIndices[_projection.visibleIndices.length - 1 - next];
      _focusedVersion = widget.versions[index];
    });
    _scrollToFocusedIndex(animated: true);
  }

  void _confirmSelection() {
    if (!ref.read(scheduleVersionPreferencesProvider).isLoaded) return;
    if (_focusedListIndex >= 0 &&
        _focusedListIndex < _projection.visibleIndices.length) {
      final actualIndex = _projection.visibleIndices[
          _projection.visibleIndices.length - 1 - _focusedListIndex];
      widget.onVersionSelected(actualIndex);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark ? Colors.orange : Colors.deepPurple;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final preference = ref.watch(scheduleVersionPreferencesProvider);
    _updateProjection(preference.hideUnchanged);
    final visible = _projection.visibleIndices;

    return Shortcuts(
      shortcuts: _filterHasFocus
          ? Map.fromEntries(_versionShortcuts.entries
              .where((entry) => entry.value is _VersionCloseIntent))
          : _versionShortcuts,
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
                          const Flexible(
                              child: Text(
                            "Оберіть версію",
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          )),
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
                    if (widget.contextLabel != null)
                      Text(widget.contextLabel!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ScheduleVersionFilterTile(
                      compact: true,
                      onFocusChange: (focused) {
                        if (mounted) setState(() => _filterHasFocus = focused);
                      },
                    ),
                    if (!preference.isLoaded)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Показано ${visible.length} із '
                            '${widget.versions.length} публікацій'),
                      ),
                    if (preference.isLoaded && visible.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'Немає збережених версій для цієї групи та дати'),
                      ),
                    if (preference.isLoaded)
                      Flexible(
                        child: ListView.separated(
                          controller: _scrollController,
                          shrinkWrap: true,
                          itemCount: visible.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final versionIndex =
                                visible[visible.length - 1 - index];
                            final version = widget.versions[versionIndex];
                            final effectiveSelected =
                                widget.selectedVersionIndex >= 0
                                    ? widget.selectedVersionIndex
                                    : widget.versions.length - 1;
                            final isSelected = versionIndex ==
                                _projection
                                    .representativeFor(effectiveSelected);
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
                                subtitle: Text('(${version.outageString})'
                                    '${version.isManual ? ' · Ручне редагування' : ''}'
                                    '${!preference.hideUnchanged && _projection.unchanged[versionIndex] ? ' · Без змін для цієї групи' : ''}'),
                                trailing: isSelected
                                    ? const Icon(Icons.check,
                                        color: Colors.green)
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
