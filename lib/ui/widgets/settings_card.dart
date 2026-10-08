import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/app_logger.dart';
import '../../services/preferences_helper.dart';

/// A reusable collapsible settings card with consistent theme styling,
/// smooth expand/collapse animations, accessible semantics, and optional SharedPreferences persistence.
class SettingsCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;
  final String? persistenceKey;
  final Widget? trailing;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? margin;
  final bool collapsible;

  const SettingsCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.children,
    this.initiallyExpanded = true,
    this.persistenceKey,
    this.trailing,
    this.onExpansionChanged,
    this.contentPadding,
    this.margin,
    this.collapsible = true,
  });

  @override
  State<SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<SettingsCard>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _controller;
  late Animation<double> _heightFactor;
  late Animation<double> _iconTurns;
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.collapsible ? widget.initiallyExpanded : true;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
      value: _isExpanded ? 1.0 : 0.0,
    );
    _heightFactor = _controller.drive(CurveTween(curve: Curves.easeInOut));
    _iconTurns = _controller.drive(Tween<double>(begin: 0.0, end: 0.5)
        .chain(CurveTween(curve: Curves.easeInOut)));

    if (widget.collapsible && widget.persistenceKey != null) {
      _loadSavedState();
    }
  }

  @override
  void didUpdateWidget(covariant SettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.collapsible && !_isExpanded) {
      setState(() {
        _isExpanded = true;
        _controller.value = 1.0;
      });
    } else if (widget.collapsible &&
        oldWidget.persistenceKey != widget.persistenceKey) {
      _userToggled = false;
      if (widget.persistenceKey != null) {
        _loadSavedState();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      if (!mounted || _userToggled) return;

      final saved = prefs.getBool(widget.persistenceKey!);
      if (saved != null && saved != _isExpanded && mounted && !_userToggled) {
        setState(() {
          _isExpanded = saved;
          _controller.value = saved ? 1.0 : 0.0;
        });
      }
    } catch (e) {
      AppLogger.w(
        'Failed to load settings card state for ${widget.persistenceKey}: $e',
        tag: 'SettingsCard',
      );
    }
  }

  Future<void> _toggle() async {
    if (!widget.collapsible) return;

    _userToggled = true;
    final newState = !_isExpanded;
    setState(() => _isExpanded = newState);

    if (newState) {
      _controller.forward();
    } else {
      _controller.reverse();
    }

    widget.onExpansionChanged?.call(newState);

    if (widget.persistenceKey != null) {
      try {
        final prefs = await PreferencesHelper.getSafeInstance();
        await prefs.setBool(widget.persistenceKey!, newState);
      } catch (e) {
        AppLogger.w(
          'Failed to persist settings card state for ${widget.persistenceKey}: $e',
          tag: 'SettingsCard',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Use theme card color to support custom darkness themes (STALKER, Cyberpunk, etc.)
    final cardBg = theme.cardTheme.color ??
        (isDark ? const Color(0xFF1E1E1E) : colorScheme.surface);

    final borderColor = colorScheme.outlineVariant.withValues(
      alpha: isDark ? 0.25 : 0.45,
    );

    return Container(
      margin: widget.margin ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: widget.collapsible,
              expanded: widget.collapsible ? _isExpanded : null,
              label: widget.title,
              hint: widget.collapsible
                  ? (_isExpanded ? 'Згорнути секцію' : 'Розгорнути секцію')
                  : null,
              child: InkWell(
                onTap: widget.collapsible ? _toggle : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(
                        widget.icon,
                        size: 22,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (widget.subtitle != null &&
                                widget.subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.subtitle!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (widget.trailing != null) ...[
                        widget.trailing!,
                        const SizedBox(width: 8),
                      ],
                      if (widget.collapsible)
                        RotationTransition(
                          turns: _iconTurns,
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.8),
                            size: 22,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _controller.view,
              builder: (context, child) {
                final isClosed = !_isExpanded && _controller.isDismissed;
                return ClipRect(
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: _heightFactor.value,
                    child: isClosed ? const SizedBox.shrink() : child,
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: borderColor.withValues(alpha: isDark ? 0.12 : 0.22),
                  ),
                  Padding(
                    padding: widget.contentPadding ??
                        const EdgeInsets.only(top: 4, bottom: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: widget.children,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
