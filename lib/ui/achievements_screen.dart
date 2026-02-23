import 'package:flutter/material.dart';

import '../models/achievement.dart';
import '../services/achievement_service.dart';

class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen>
    with SingleTickerProviderStateMixin {
  Map<String, AchievementState> _states = {};
  bool _isLoading = true;
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat();
    _loadData();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final states = await AchievementService().loadAllStates();
    if (mounted) {
      setState(() {
        _states = states;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unlockedTotal =
        _states.values.where((s) => s.unlocked).length;
    final total = AchievementCatalog.all.length;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0A0A0A) : Colors.grey[50],
      appBar: AppBar(
        title: const Text('Досягнення'),
        centerTitle: true,
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.orange.withOpacity(0.15)
                      : Colors.deepPurple.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.orange.withOpacity(0.3)
                        : Colors.deepPurple.withOpacity(0.3),
                  ),
                ),
                child: Text(
                  '🏆 $unlockedTotal / $total',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isDark ? Colors.orange : Colors.deepPurple,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.orange))
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                // Прогрес-хедер
                _buildProgressHeader(isDark, unlockedTotal, total),
                // Категорії
                for (final cat in AchievementCategory.values)
                  _buildCategorySection(cat, isDark),
              ],
            ),
    );
  }

  Widget _buildProgressHeader(bool isDark, int unlocked, int total) {
    final ratio = total > 0 ? unlocked / total : 0.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
              : [Colors.deepPurple.shade50, Colors.blue.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.orange.withOpacity(0.2)
              : Colors.deepPurple.withOpacity(0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.orange.withOpacity(0.05)
                : Colors.deepPurple.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            _getStatusEmoji(ratio),
            style: const TextStyle(fontSize: 40),
          ),
          const SizedBox(height: 12),
          Text(
            _getStatusText(ratio),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: isDark
                  ? Colors.white.withOpacity(0.1)
                  : Colors.black.withOpacity(0.08),
              valueColor: AlwaysStoppedAnimation(
                isDark ? Colors.orange : Colors.deepPurple,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(ratio * 100).toStringAsFixed(0)}% завершено',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusEmoji(double ratio) {
    if (ratio >= 1.0) return '👑';
    if (ratio >= 0.75) return '🔥';
    if (ratio >= 0.50) return '⚡';
    if (ratio >= 0.25) return '💪';
    if (ratio > 0) return '🌱';
    return '🌑';
  }

  String _getStatusText(double ratio) {
    if (ratio >= 1.0) return 'Абсолютний Мастер Тьми!';
    if (ratio >= 0.75) return 'Легенда блекаутів!';
    if (ratio >= 0.50) return 'Досвідчений виживальник';
    if (ratio >= 0.25) return 'На правильному шляху';
    if (ratio > 0) return 'Початок подорожі';
    return 'Ще попереду…';
  }

  Widget _buildCategorySection(AchievementCategory cat, bool isDark) {
    final achs = AchievementCatalog.byCategory(cat);
    final unlockedInCat = achs
        .where((a) => _states[a.id]?.unlocked == true)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  AchievementCatalog.categoryTitle(cat),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withOpacity(0.06)
                      : Colors.black.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$unlockedInCat / ${achs.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            AchievementCatalog.categorySubtitle(cat),
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ),
        ...achs.map((ach) => _buildAchievementTile(ach, isDark)),
      ],
    );
  }

  Widget _buildAchievementTile(AchievementDef ach, bool isDark) {
    final state = _states[ach.id];
    final unlocked = state?.unlocked == true;
    final progress = state?.progress ?? 0.0;
    final isSecret = ach.isSecret && !unlocked;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: unlocked
            ? (isDark
                ? ach.color.withOpacity(0.12)
                : ach.color.withOpacity(0.08))
            : (isDark
                ? Colors.white.withOpacity(0.04)
                : Colors.white),
        border: Border.all(
          color: unlocked
              ? ach.color.withOpacity(0.4)
              : (isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.06)),
          width: unlocked ? 1.5 : 1.0,
        ),
        boxShadow: unlocked
            ? [
                BoxShadow(
                  color: ach.color.withOpacity(0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showAchievementDetails(ach, state, isDark),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Іконка
                _buildIconBadge(ach, unlocked, isSecret, isDark),
                const SizedBox(width: 14),
                // Текст
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSecret ? '???' : ach.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: unlocked
                              ? (isDark ? Colors.white : Colors.black87)
                              : (isDark ? Colors.white54 : Colors.black45),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isSecret
                            ? 'Умова прихована. Продовжуйте грати!'
                            : ach.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: unlocked
                              ? (isDark ? Colors.white60 : Colors.black54)
                              : (isDark ? Colors.white30 : Colors.black38),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Прогрес-бар (для НЕ секретних)
                      if (!unlocked && !isSecret && progress > 0) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: isDark
                                ? Colors.white.withOpacity(0.08)
                                : Colors.black.withOpacity(0.06),
                            valueColor:
                                AlwaysStoppedAnimation(ach.color.withOpacity(0.6)),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(progress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white30 : Colors.black38,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Статус
                if (unlocked)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('✅', style: TextStyle(fontSize: 20)),
                  )
                else
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: isDark
                        ? Colors.white.withOpacity(0.15)
                        : Colors.black.withOpacity(0.12),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconBadge(
      AchievementDef ach, bool unlocked, bool isSecret, bool isDark) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: unlocked
            ? LinearGradient(
                colors: [ach.color, ach.color.withOpacity(0.7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: unlocked
            ? null
            : (isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.05)),
        boxShadow: unlocked
            ? [
                BoxShadow(
                  color: ach.color.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Icon(
        isSecret ? Icons.help_outline : ach.icon,
        color: unlocked
            ? Colors.white
            : (isDark ? Colors.white24 : Colors.black26),
        size: 26,
      ),
    );
  }

  void _showAchievementDetails(
      AchievementDef ach, AchievementState? state, bool isDark) {
    final unlocked = state?.unlocked == true;
    final isSecret = ach.isSecret && !unlocked;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Іконка велика
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: unlocked
                    ? LinearGradient(
                        colors: [ach.color, ach.color.withOpacity(0.6)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: unlocked
                    ? null
                    : (isDark ? Colors.white10 : Colors.grey[200]),
                boxShadow: unlocked
                    ? [
                        BoxShadow(
                          color: ach.color.withOpacity(0.4),
                          blurRadius: 24,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                isSecret ? Icons.help_outline : ach.icon,
                size: 40,
                color: unlocked
                    ? Colors.white
                    : (isDark ? Colors.white30 : Colors.black26),
              ),
            ),
            const SizedBox(height: 16),
            // Назва
            Text(
              isSecret ? '???' : ach.title,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            // Категорія
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: ach.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                AchievementCatalog.categoryTitle(ach.category),
                style: TextStyle(
                  fontSize: 12,
                  color: ach.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Опис
            Text(
              isSecret
                  ? 'Це приховане досягнення. Продовжуйте користуватись додатком, щоб відкрити його!'
                  : ach.description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black54,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            // Умова
            if (!isSecret)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withOpacity(0.05)
                      : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: isDark ? Colors.white30 : Colors.black38,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ach.conditionText,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // Прогрес
            if (!unlocked && !isSecret && (state?.progress ?? 0) > 0) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: state!.progress,
                  minHeight: 8,
                  backgroundColor: isDark
                      ? Colors.white.withOpacity(0.08)
                      : Colors.black.withOpacity(0.06),
                  valueColor: AlwaysStoppedAnimation(ach.color),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Прогрес: ${(state.progress * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ],
            // Дата розблокування
            if (unlocked && state?.unlockedAt != null) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Colors.green[400],
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Розблоковано: ${_formatDate(state!.unlockedAt!)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green[400],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}'
        '  ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Оверлей-сповіщення про нове досягнення (для показу поверх контенту).
class AchievementUnlockedOverlay {
  static OverlayEntry? _currentOverlay;

  static void show(BuildContext context, AchievementDef achievement) {
    _currentOverlay?.remove();

    final overlay = OverlayEntry(
      builder: (ctx) => _AchievementToast(
        achievement: achievement,
        onDismiss: () {
          _currentOverlay?.remove();
          _currentOverlay = null;
        },
      ),
    );
    _currentOverlay = overlay;
    Overlay.of(context).insert(overlay);
  }
}

class _AchievementToast extends StatefulWidget {
  final AchievementDef achievement;
  final VoidCallback onDismiss;

  const _AchievementToast({
    required this.achievement,
    required this.onDismiss,
  });

  @override
  State<_AchievementToast> createState() => _AchievementToastState();
}

class _AchievementToastState extends State<_AchievementToast>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnimation = Tween<double>(begin: -100, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _opacityAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _controller.forward();

    // Авто-закриття через 4 секунди
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        _controller.reverse().then((_) => widget.onDismiss());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ach = widget.achievement;

    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 16,
      right: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (ctx, child) => Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: child,
          ),
        ),
        child: GestureDetector(
          onTap: widget.onDismiss,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: [
                    ach.color.withOpacity(0.9),
                    ach.color.withOpacity(0.7),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: ach.color.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.2),
                    ),
                    child: Icon(ach.icon, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '🏆 Нове досягнення!',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ach.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          ach.description,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
    );
  }
}


