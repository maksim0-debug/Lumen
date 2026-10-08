import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/parser_service.dart';

void main() {
  group('ParserService Emergency Shutdown Extraction Tests', () {
    final cases = jsonDecode(File('test/fixtures/emergency_status_cases.json')
        .readAsStringSync()) as List<dynamic>;
    for (final item in cases.cast<Map<String, dynamic>>()) {
      test(item['name'] as String, () {
        expect(
            ParserService.analyzeEmergencyStatus(item['html'] as String)
                .isEmergency,
            item['active']);
      });
    }

    test(
        'extractEmergencyStatus returns false when only FAQ mentions emergency outages without modal',
        () {
      const faqHtmlOnly = '''
<!DOCTYPE html>
<html>
<head><title>Розклад відключень</title></head>
<body>
  <div class="faq">
    <p>Спершу перевірте, чи є інформація про аварійні, графіки або екстрені відключення за вашою адресою.</p>
    <p>Якщо немає світла у білій зоні графіка – це можуть бути екстрені відключення.</p>
    <p>Чим відрізняються стабілізаційні відключення за графіками та екстрені відключення?</p>
  </div>
</body>
</html>
''';

      final isEmergency = ParserService.extractEmergencyStatus(faqHtmlOnly);
      expect(isEmergency, isFalse);
    });

    test('extractEmergencyStatus returns false for empty or regular HTML', () {
      expect(ParserService.extractEmergencyStatus(''), isFalse);
      expect(
          ParserService.extractEmergencyStatus(
              '<html><body><h1>Hello</h1></body></html>'),
          isFalse);
    });

    test(
        'extractEmergencyStatus detects modal-attention with exact intro phrase',
        () {
      const modalHtml = '''
<div class="m-attention micromodal-slide" id="modal-attention" aria-hidden="true">
  <div class="modal__overlay">
    <div class="modal__container">
      <div class="m-attention__body">
        <div class="m-attention__text">
          <p>За наказом НЕК Укренерго <strong>введені екстрені відключення</strong> електроенергії.<br />Графіки відключень при цьому не діють.</p>
        </div>
      </div>
    </div>
  </div>
</div>
''';

      expect(ParserService.extractEmergencyStatus(modalHtml), isTrue);
    });

    test(
        'extractEmergencyStatus returns false if modal-attention has unrelated text',
        () {
      const unrelatedModalHtml = '''
<div class="m-attention micromodal-slide" id="modal-attention" aria-hidden="true">
  <div class="modal__overlay">
    <div class="modal__container">
      <div class="m-attention__body">
        <div class="m-attention__text">
          <p>Технічні роботи на сайті з 02:00 до 03:00.</p>
        </div>
      </div>
    </div>
  </div>
</div>
''';
      expect(ParserService.extractEmergencyStatus(unrelatedModalHtml), isFalse);
    });

    test('extractEmergencyStatus handles uppercase and Cyrillic variations',
        () {
      const upperHtml = '''
<div id="modal-attention">
  <div class="m-attention__text">
    ЗА НАКАЗОМ НЕК УКРЕНЕРГО ВВЕДЕНІ ЕКСТРЕНІ ВІДКЛЮЧЕННЯ
  </div>
</div>
''';
      expect(ParserService.extractEmergencyStatus(upperHtml), isTrue);
    });

    test(
        'extractEmergencyStatus returns false for planned outage warnings in modal',
        () {
      const plannedHtml = '''
<div id="modal-attention">
  <div class="m-attention__text">
    Введені планові ремонтні роботи в мережі.
  </div>
</div>
''';
      expect(ParserService.extractEmergencyStatus(plannedHtml), isFalse);
    });
  });
}
