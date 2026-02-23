import 'package:flutter/material.dart';

class PowerMonitorGuideScreen extends StatelessWidget {
  const PowerMonitorGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              'Додаток "Люмен" дозволяє відстежувати реальну наявність світла у вас вдома, а не лише покладатись на графіки ДТЕК. Для цього потрібен пристрій, який буде знаходитись вдома і відправляти дані в базу при зникненні або появі 220В.',
              style: TextStyle(fontSize: 15),
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
            const Text('1. Створіть безкоштовний проект на Firebase.\n'
                '2. Відкрийте Realtime Database.\n'
                '3. У вкладці "Rules" (Правила) встановіть:\n'
                '   ".read": true\n'
                '   ".write": true\n'
                '   (Це найпростіший спосіб без аутентифікації).\n'
                '4. Скопіюйте URL вашої бази (наприклад: https://my-home-db.europe-west1.firebasedatabase.app).\n'
                '5. Вставте цей URL в налаштуваннях "Люмен".'),
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
              'Найпростіший спосіб — використати старий смартфон на Android, який завжди підключений до зарядки вдома. На нього потрібно встановити безкоштовний додаток MacroDroid.',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.amber, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Важливо про Інтернет:\nКоли світло зникає, Wi-Fi роутер вимикається миттєво. Щоб телефон встиг відправити сигнал "Світла немає", роутер повинен бути заживлений від міні-ДБЖ, АБО телефон має працювати від мобільного інтернету.',
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
            const Text('Тригери:\n• Живлення відключено (Будь-який тип).'),
            const SizedBox(height: 4),
            const Text('Дії:\n'
                '• Умова (Опціонально): Якщо змінна is_light_off = Хибність (щоб уникнути дублів).\n'
                '• Макроси (Локальні змінні): Встановити змінну is_light_off = Істина (Тип: Логічний).\n'
                '• Підключитися до вашої мережі (виберіть мережу зі списку)\n'
                '• Очікування (Затримка): 10-15 секунд\n'
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
                      : Colors.black.withOpacity(0.05),
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
                'Роутер завантажується 2-3 хвилини. Щоб додаток зафіксував точний час появи світла, ми запам\'ятовуємо час одразу, а відправляємо його пізніше.',
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
            const SizedBox(height: 8),
            const Text('Тригери:\n• Живлення підключено (Будь-який тип).'),
            const SizedBox(height: 4),
            const Text('Дії:\n'
                '• Умова IF: Якщо змінна is_light_off = Істина.\n'
                '• Макроси (Локальні змінні): Встановити змінну fixed_timestamp (Тип: Рядок). Значення: [year]-[month_digit]-[dayofmonth] [hour]:[minute]:[second]\n'
                '• Очікування (Затримка): 1 хвилина 30 секунд (даємо роутеру завантажитись).\n'
                '• Мережа -> Налаштувати Wi-Fi: Вимкнути Wi-Fi.\n'
                '• Очікування: 5 секунд.\n'
                '• Мережа -> Налаштувати Wi-Fi: Увімкнути Wi-Fi.\n'
                '• Підключитися до вашої мережі (виберіть мережу зі списку)\n'
                '• Очікування: 10 секунд (чекаємо підключення до домашньої мережі).\n'
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
                      : Colors.black.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text(
                '{\n  "status": "online",\n  "timestamp": "[lv=fixed_timestamp]",\n  "device": "old_phone"\n}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const Text(
                '• Макроси (Локальні змінні): Встановити змінну is_light_off = Хибність.\n'
                '• Кінець умови (End IF).'),
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
                'Ви можете написати скрипт на MikroTik (Netwatch / scheduler) або OpenWrt (cron), який при завантаженні роутера відправляє статус "online".'),
            const SizedBox(height: 8),
            const Text(
                'Статус "offline" в цьому випадку доведеться фіксувати зовнішнім сервером (VPS) або іншим пристроєм, оскільки вимкнений роутер нічого не відправить.'),
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
                'Мікроконтролер, підключений у розетку. При завантаженні (відновлення живлення) відправляє "online".'),
            const SizedBox(height: 8),
            const Text(
                'Для фіксації "offline" можна використовувати конденсатор/акумулятор (щоб встигнути відправити сигнал перед остаточним вимкненням) або використовувати серверну перевірку (Watchdog).'),
          ],
        ),
      ),
    );
  }
}
