import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Cross-platform and keyboard-layout independent shortcut activator.
///
/// Unlike standard [SingleActivator], [AppShortcutActivator]:
/// 1. Accepts both [LogicalKeyboardKey] and [PhysicalKeyboardKey], allowing
///    letter hotkeys to trigger seamlessly regardless of active OS layout
///    (e.g., Ukrainian ЙЦУКЕН vs English QWERTY).
/// 2. Treats [control] as `Control` on Windows/Linux and either `Control` or
///    `Command` (Meta) on macOS, conforming to standard desktop UX conventions.
/// 3. Supports repeat events when [includeRepeats] is true.
@immutable
class AppShortcutActivator with Diagnosticable implements ShortcutActivator {
  final LogicalKeyboardKey trigger;
  final PhysicalKeyboardKey? physicalKey;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;
  final bool includeRepeats;

  const AppShortcutActivator(
    this.trigger, {
    this.physicalKey,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.includeRepeats = true,
  });

  static final Set<LogicalKeyboardKey> _controlSynonyms = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
  };
  static final Set<LogicalKeyboardKey> _shiftSynonyms = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };
  static final Set<LogicalKeyboardKey> _altSynonyms = <LogicalKeyboardKey>{
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
  };
  static final Set<LogicalKeyboardKey> _metaSynonyms = <LogicalKeyboardKey>{
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  @override
  Iterable<LogicalKeyboardKey>? get triggers =>
      physicalKey == null ? <LogicalKeyboardKey>[trigger] : null;

  bool _shouldAcceptModifiers(Set<LogicalKeyboardKey> pressed) {
    final bool hasControl = pressed.intersection(_controlSynonyms).isNotEmpty;
    final bool hasMeta = pressed.intersection(_metaSynonyms).isNotEmpty;
    final bool hasShift = pressed.intersection(_shiftSynonyms).isNotEmpty;
    final bool hasAlt = pressed.intersection(_altSynonyms).isNotEmpty;

    final bool isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final bool effectiveControl;
    final bool effectiveMeta;

    if (isMac && control && !meta) {
      // On macOS, shortcuts requesting control (e.g. Ctrl+C) accept either Cmd (Meta) or Control.
      effectiveControl = hasControl || hasMeta;
      effectiveMeta = false;
    } else {
      effectiveControl = hasControl;
      effectiveMeta = hasMeta;
    }

    return control == effectiveControl &&
        shift == hasShift &&
        alt == hasAlt &&
        meta == effectiveMeta;
  }

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent &&
        (!includeRepeats || event is! KeyRepeatEvent)) {
      return false;
    }

    final bool keyMatches = event.logicalKey == trigger ||
        (physicalKey != null && event.physicalKey == physicalKey);

    if (!keyMatches) {
      return false;
    }

    return _shouldAcceptModifiers(state.logicalKeysPressed);
  }

  @override
  String debugDescribeKeys() {
    final keys = <String>[
      if (control) 'Control',
      if (alt) 'Alt',
      if (meta) 'Meta',
      if (shift) 'Shift',
      trigger.debugName ?? trigger.toStringShort(),
    ];
    return keys.join(' + ');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppShortcutActivator &&
        other.trigger == trigger &&
        other.physicalKey == physicalKey &&
        other.control == control &&
        other.shift == shift &&
        other.alt == alt &&
        other.meta == meta &&
        other.includeRepeats == includeRepeats;
  }

  @override
  int get hashCode => Object.hash(
        trigger,
        physicalKey,
        control,
        shift,
        alt,
        meta,
        includeRepeats,
      );
}
