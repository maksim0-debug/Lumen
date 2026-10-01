import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'services/app_logger.dart';
import 'services/darkness_theme_service.dart';
import 'services/preferences_helper.dart';
import 'theme/app_theme.dart';
import 'ui/home_screen.dart';

class LumenApp extends StatefulWidget {
  const LumenApp({super.key});

  @override
  State<LumenApp> createState() => _LumenAppState();
}

class _LumenAppState extends State<LumenApp> {
  bool _isDarkMode = true;
  bool _autoDarknessTheme = false;
  double _uiScale = 1.0;
  final DarknessThemeService _darknessThemeService = DarknessThemeService();
  DarknessStage _currentDarknessStage = DarknessStage.solarpunk;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _initDarknessTheme();
  }

  @override
  void dispose() {
    _darknessThemeService.onStageChanged = null;
    super.dispose();
  }

  Future<void> _initDarknessTheme() async {
    _darknessThemeService.onStageChanged = (stage) {
      if (mounted) {
        setState(() {
          _currentDarknessStage = stage;
        });
      }
    };
    await _darknessThemeService.init();
    if (mounted) {
      setState(() {
        _autoDarknessTheme = _darknessThemeService.isEnabled;
        _currentDarknessStage = _darknessThemeService.currentStage;
      });
    }
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      if (mounted) {
        setState(() {
          _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
          _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
          _autoDarknessTheme = _darknessThemeService.isEnabled;
          _currentDarknessStage = _darknessThemeService.currentStage;
        });
      }
    } catch (e) {
      AppLogger.e("Error loading theme", tag: 'Main', error: e);
    }
  }

  void _toggleTheme() {
    _loadTheme();
    // Також оновити стадію тьми
    _darknessThemeService.refresh();
    if (mounted) {
      setState(() {
        _autoDarknessTheme = _darknessThemeService.isEnabled;
        _currentDarknessStage = _darknessThemeService.currentStage;
      });
    }
  }

  void _reloadScale() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      if (mounted) {
        setState(() {
          _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
        });
      }
    } catch (e) {
      AppLogger.e("Error reloading scale", tag: 'Main', error: e);
    }
  }

  ThemeData get _activeTheme {
    if (_autoDarknessTheme) {
      return _darknessThemeService.getThemeForStage(_currentDarknessStage);
    }
    return _isDarkMode ? AppTheme.darkTheme : AppTheme.lightTheme;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Люмен',
      debugShowCheckedModeBanner: false,
      theme: _activeTheme,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('uk', 'UA'),
      ],
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_uiScale),
          ),
          child: child!,
        );
      },
      home: HomeScreen(
        onThemeChanged: _toggleTheme,
        onScaleChanged: _reloadScale,
      ),
    );
  }
}

typedef MyApp = LumenApp;