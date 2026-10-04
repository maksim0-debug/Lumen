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
  });
}

