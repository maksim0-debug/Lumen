import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/parser_service.dart';

void main() {
  group('ParserService JSON extraction & Anti-Bot Detection Tests', () {
    test('extractJsonFromHtml extracts valid DisconSchedule.fact block', () {
      const html = '''
<!DOCTYPE html>
<html>
<head><title>Розклад відключень</title></head>
<body>
<script>
  window.someVar = 1;
  DisconSchedule.fact = {"today":1727730000,"data":{"GPV1.1":{"today":[]}},"update":"01.10.2026 06:00"};
  DisconSchedule.showCurOutage();
</script>
</body>
</html>
''';

      final json = ParserService().extractJsonFromHtml(html);
      expect(json, contains('"today":1727730000'));
      expect(json, contains('"GPV1.1"'));
    });

    test(
        'extractJsonFromHtml returns empty string on malformed or missing fact block',
        () {
      const html = '<html><body><h1>No schedules here</h1></body></html>';
      final json = ParserService().extractJsonFromHtml(html);
      expect(json, isEmpty);
    });

    test('isBotChallengeHtml detects Imperva Incapsula challenge', () {
      const impervaChallenge = '''
<html>
<head>
<META NAME="robots" CONTENT="noindex,nofollow">
<script src="/_Incapsula_Resource?SWJIYLWA=5074a744e2e3d891814e9a2dace20bd4,719d34d31c8e3a6e6fffd425f7e032f3">
</script>
<body>
</body></html>
''';

      expect(ParserService.isBotChallengeHtml(impervaChallenge), isTrue);
      expect(
          ParserService.isBotChallengeHtml(
              '<html><body>Hello world</body></html>'),
          isFalse);
    });

    test(
        'isBotChallengeHtml detects Imperva Error 15 and country policy blocks',
        () {
      const error15Html = '''
<!DOCTYPE html>
<html lang="uk">
<head><title>Access Denied</title></head>
<body>
  <h2>Ви намагаєтесь підключитися до сайту з адреси країни, яка заблокована нашою політикою безпеки.</h2>
  <h3>You are trying to connect to the site from a country address that is blocked by our security policy.</h3>
  <h1>Error 15</h1>
  <div>Powered by imperva</div>
</body>
</html>
''';

      expect(ParserService.isBotChallengeHtml(error15Html), isTrue);
      expect(
          ParserService.isBotChallengeHtml(
              'Error 15: Access Denied. Powered by imperva'),
          isTrue);
      expect(
          ParserService.isBotChallengeHtml(
              'підключитися до сайту з адреси країни, яка заблокована нашою політикою безпеки'),
          isTrue);
      expect(ParserService.isBotChallengeHtml('blocked by our security policy'),
          isTrue);
    });
  });
}
