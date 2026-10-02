import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_intents.dart';

/// Wraps a screen with keyboard shortcuts and actions handling,
/// maintaining robust focus and preventing collisions when typing in TextFields.
class KeyboardShortcutWrapper extends StatefulWidget {
  final Map<ShortcutActivator, Intent> shortcuts;
  final Map<Type, Action<Intent>> actions;
  final Widget child;
  final FocusNode? focusNode;
  final bool autofocus;

  const KeyboardShortcutWrapper({
    super.key,
    required this.shortcuts,
    required this.actions,
    required this.child,
    this.focusNode,
    this.autofocus = true,
  });

  @override
  State<KeyboardShortcutWrapper> createState() =>
      _KeyboardShortcutWrapperState();
}

class _KeyboardShortcutWrapperState extends State<KeyboardShortcutWrapper> {
  FocusNode? _internalFocusNode;
  late Map<Type, Action<Intent>> _guardedActions;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(debugLabel: 'KeyboardShortcutWrapper'));

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode(debugLabel: 'KeyboardShortcutWrapper');
    }
    _updateGuardedActions();
  }

  @override
  void didUpdateWidget(KeyboardShortcutWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(widget.actions, oldWidget.actions)) {
      _updateGuardedActions();
    }
  }

  @override
  void dispose() {
    _internalFocusNode?.dispose();
    super.dispose();
  }

  /// Checks if current primary focus is within an editable text widget.
  bool _isEditingText() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    final context = primary.context;
    if (context == null || !context.mounted) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null ||
        context.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _updateGuardedActions() {
    final guarded = <Type, Action<Intent>>{};
    widget.actions.forEach((type, action) {
      guarded[type] = _GuardedAction<Intent>(
        originalAction: action,
        isEditingText: _isEditingText,
      );
    });
    _guardedActions = guarded;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: widget.shortcuts,
      child: Actions(
        actions: _guardedActions,
        child: Focus(
          focusNode: _effectiveFocusNode,
          autofocus: widget.autofocus,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Custom action wrapper that suppresses shortcut handling when editing text,
/// preventing single-character and navigation keys from hijacking text input.
class _GuardedAction<T extends Intent> extends Action<T> {
  final Action<T> originalAction;
  final bool Function() isEditingText;

  _GuardedAction({
    required this.originalAction,
    required this.isEditingText,
  });

  @override
  bool isEnabled(covariant T intent) {
    if (isEditingText()) {
      // While typing in an input field, Escape is permitted to unfocus,
      // and SaveEditorDataIntent (Ctrl+S) is permitted to save data.
      // Returning false for all other shortcuts causes ShortcutManager to ignore them,
      // allowing normal characters and cursor navigation keys to pass to EditableText.
      return intent is CloseTopModalOrGoBackIntent ||
          intent is SaveEditorDataIntent;
    }
    return originalAction.isEnabled(intent);
  }

  @override
  Object? invoke(covariant T intent) {
    if (isEditingText() && intent is CloseTopModalOrGoBackIntent) {
      FocusManager.instance.primaryFocus?.unfocus();
      return null;
    }
    return originalAction.invoke(intent);
  }
}
