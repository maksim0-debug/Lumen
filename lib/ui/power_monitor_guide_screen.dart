import 'package:flutter/material.dart';

import 'dialogs/shortcut_help_dialog.dart';
import 'shortcuts/app_intents.dart';
import 'shortcuts/keyboard_shortcut_wrapper.dart';
import 'shortcuts/shortcut_registry.dart';

class PowerMonitorGuideScreen extends StatelessWidget {
  const PowerMonitorGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyboardShortcutWrapper(
      shortcuts: AppKeyboardShortcuts.modalShortcuts,
      actions: {
        CloseTopModalOrGoBackIntent:
            CallbackAction<CloseTopModalOrGoBackIntent>(
          onInvoke: (intent) {
            Navigator.of(context).maybePop();
            return null;
          },
        ),
        ToggleShortcutHelpIntent: CallbackAction<ToggleShortcutHelpIntent>(
          onInvoke: (intent) {
            ShortcutHelpDialog.show(context);
            return null;
          },
        ),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Як налаштувати сенсор?'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildIntroCard(context),
            const SizedBox(height: 16),
            _buildFirebaseCard(context),
            const SizedBox(height: 16),
            _buildMethod1Card(context),
            const SizedBox(height: 16),
            _buildMethod2Card(context),
            const SizedBox(height: 16),
            _buildMethod3Card(context),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroCard(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue),
                const SizedBox(width: 8),
                Text('Вступ', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Застосунок «Люмен» дає змогу відстежувати реальну наявність світла у вас вдома, а не лише покладатися на графіки ДТЕК. Для цього потрібен пристрій, який перебуватиме вдома й надсилатиме дані до бази у разі зникнення чи появи 220 В.',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black26
                    : Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('💡 Застосунок підтримує 3 дійсні статуси:',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(height: 4),
                  Text(
                      '• 🟢 ON — живлення є, сенсор активний та надсилає дані.',
                      style: TextStyle(fontSize: 12)),
                  Text('• 🔴 OFF — живлення відсутнє (зафіксовано блекаут).',
                      style: TextStyle(fontSize: 12)),
                  Text(
                      '• ⚪ UNKNOWN — дані застаріли (понад встановлений таймаут: 5, 15, 25 хв тощо), сенсор вимкнувся або відсутній інтернет.',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFirebaseCard(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storage, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Вимоги до бази даних (Firebase)',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('1. Створіть безплатний проєкт у Firebase.\n'
                '2. Відкрийте Realtime Database.\n'
                '3. У вкладці «Rules» (Правила) встановіть:\n'
                '   ".read": true\n'
                '   ".write": true\n'
                '   (Це найпростіший спосіб без автентифікації).\n'
                '4. Скопіюйте URL вашої бази (наприклад: https://my-home-db.europe-west1.firebasedatabase.app).\n'
                '5. Вставте цей URL у налаштування «Люмен».'),
          ],
        ),
      ),
    );
  }

  Widget _buildMethod1Card(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smartphone, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Спосіб 1: Старий Android-смартфон (Рекомендовано)',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Найпростіший спосіб — використати старий смартфон на Android, який завжди під\'єднаний до зарядного пристрою вдома. На нього потрібно встановити безплатний застосунок MacroDroid.',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.amber, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Важливо про інтернет:\nКоли світло зникає, Wi-Fi-роутер вимикається миттєво. Щоб телефон встиг надіслати сигнал «Світла немає», роутер має живитися від міні-ДБЖ, АБО телефон повинен працювати від мобільного інтернету.',
                        style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('У MacroDroid створіть два макроси.',
                style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),
            const Text('Макрос 1: Світло ЗНИКЛО (Light OFF)',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.red)),
            const SizedBox(height: 4),
            const Text('Тригери:\n• Живлення від\'єднано (Будь-який тип).'),
            const SizedBox(height: 4),
            const Text('Дії:\n'
                '• Умова (Опціонально): Якщо змінна is_light_off = Хибність (щоб уникнути дублів).\n'
                '• Макроси (Локальні змінні): Встановити змінну is_light_off = Істина (Тип: Логічний).\n'
                '• Під\'єднатися до вашої мережі (виберіть мережу зі списку)\n'
                '• Очікування (Затримка): 10–15 секунд\n'
                '• Додатки -> HTTP-запит:\n'
                '  - Метод: POST\n'
                '  - URL: [ВАШ_FIREBASE_URL]/events.json\n'
                '  - Content Type: application/json\n'
                '  - Тіло (Text):'),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black26
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text(
                '{\n  "status": "offline",\n  "timestamp": "[year]-[month_digit]-[dayofmonth] [hour]:[minute]:[second]",\n  "device": "old_phone"\n}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Макрос 2: Світло З\'ЯВИЛОСЯ (Light ON)',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.green)),
            const SizedBox(height: 4),
            const Text(
                'Роутер завантажується 2–3 хвилини. Щоб застосунок зафіксував точний час появи світла, ми запам\'ятовуємо час одразу, а надсилаємо його пізніше.',
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
            const SizedBox(height: 8),
            const Text('Тригери:\n• Живлення під\'єднано (Будь-який тип).'),
            const SizedBox(height: 4),
            const Text('Дії:\n'
                '• Умова IF: Якщо змінна is_light_off = Істина.\n'
                '• Макроси (Локальні змінні): Встановити змінну fixed_timestamp (Тип: Рядок). Значення: [year]-[month_digit]-[dayofmonth] [hour]:[minute]:[second]\n'
                '• Очікування (Затримка): 1 хвилина 30 секунд (даємо роутеру завантажитися).\n'
                '• Мережа -> Налаштувати Wi-Fi: Вимкнути Wi-Fi.\n'
                '• Очікування: 5 секунд.\n'
                '• Мережа -> Налаштувати Wi-Fi: Увімкнути Wi-Fi.\n'
                '• Під\'єднатися до вашої мережі (виберіть мережу зі списку)\n'
                '• Очікування: 10 секунд (чекаємо під\'єднання до домашньої мережі).\n'
                '• Додатки -> HTTP-запит:\n'
                '  - Метод: POST\n'
                '  - URL: [ВАШ_FIREBASE_URL]/events.json\n'
                '  - Content Type: application/json\n'
                '  - Тіло (Text):'),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black26
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text(
                '{\n  "status": "online",\n  "timestamp": "[lv=fixed_timestamp]",\n  "device": "old_phone"\n}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const Text(
                '• Макроси (Локальні змінні): Встановити змінну is_light_off = Хибність.\n'
                '• Кінець умови (End IF).'),
            const SizedBox(height: 16),
            const Text(
                'Макрос 3: Пінг активності (Heartbeat / last_seen) — РЕКОМЕНДОВАНО',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.blue)),
            const SizedBox(height: 4),
            const Text(
                'Навіщо: якщо світло не зникає або якщо телефон раптово вимкнувся/розрядився, застосунок дізнається про це через відсутність пінгу. Макрос оновлює last_seen кожні 5–15 хвилин. Якщо застосунок не бачить оновлень понад обраний у налаштуваннях таймаут (від 5 хвилин), він автоматично перемикається на сірий статус UNKNOWN. (Порада: якщо ви не налаштовуєте цей макрос, оберіть «Вимкнено» для TTL у налаштуваннях).',
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
            const SizedBox(height: 8),
            const Text(
                'Тригери:\n• Регулярний інтервал: кожні 10 або 15 хвилин.'),
            const SizedBox(height: 4),
            const Text('Дії:\n'
                '• Додатки -> HTTP-запит:\n'
                '  - Метод: PUT\n'
                '  - URL: [ВАШ_FIREBASE_URL]/last_seen.json\n'
                '  - Content Type: application/json\n'
                '  - Тіло (Text):'),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black26
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text(
                '"[year]-[month_digit]-[dayofmonth] [hour]:[minute]:[second]"',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethod2Card(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.router, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Спосіб 2: Роутер з кастомною прошивкою',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
                'Ви можете написати скрипт для MikroTik (Netwatch / scheduler) або OpenWrt (cron), який під час завантаження роутера надсилає статус "online".'),
            const SizedBox(height: 8),
            const Text(
                'Статус "offline" у цьому разі доведеться фіксувати зовнішнім сервером (VPS) або іншим пристроєм, оскільки вимкнений роутер нічого не надішле.'),
            const SizedBox(height: 8),
            const Text(
                'Також додайте періодичний пінг у cron для оновлення last_seen кожні 10 хвилин (інакше статус стане UNKNOWN у разі раптової втрати зв\'язку):\n'
                '*/10 * * * * curl -s -X PUT -d "\\"\$(date -u +\'%Y-%m-%dT%H:%M:%SZ\')\\"" [ВАШ_FIREBASE_URL]/last_seen.json\n'
                '(або через Unix timestamp: curl -s -X PUT -d \$(date +%s) [ВАШ_FIREBASE_URL]/last_seen.json)',
                style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildMethod3Card(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.memory, color: Colors.deepPurple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Спосіб 3: ESP8266 / ESP32',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
                'Мікроконтролер, під\'єднаний до розетки. Під час завантаження (після відновлення живлення) надсилає "online".'),
            const SizedBox(height: 8),
            const Text(
                'Для фіксації "offline" можна застосувати конденсатор/акумулятор (щоб встигнути надіслати сигнал перед остаточним вимкненням) або серверну перевірку (Watchdog).'),
            const SizedBox(height: 8),
            const Text(
                'Для підтримки статусу активності налаштуйте періодичний HTTP PUT-запит на /last_seen.json кожні 5–10 хвилин. Якщо живлення раптово зникне без сигналу offline, застосунок через встановлений таймаут (від 5 хвилин) автоматично увімкне статус UNKNOWN (або вимкніть TTL у налаштуваннях, якщо не використовуєте пінг).'),
          ],
        ),
      ),
    );
  }
}
