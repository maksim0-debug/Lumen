import '../models/emergency_status.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Only operational notices count. FAQ text and script contents are excluded.
class EmergencyStatusParser {
  static bool _insideIgnoredElement(Element element) {
    for (Node? parent = element.parentNode;
        parent != null;
        parent = parent.parentNode) {
      if (parent is Element &&
          ['script', 'style', 'template', 'noscript']
              .contains(parent.localName)) {
        return true;
      }
    }
    return false;
  }

  static String _text(Node node) {
    if (node is Text) return node.data;
    if (node is Element &&
        ['script', 'style', 'template', 'noscript', 'button', 'svg']
            .contains(node.localName)) {
      return '';
    }
    final content = node.nodes.map(_text).join();
    return node is Element &&
            ['p', 'div', 'br', 'li', 'h2', 'h3', 'h4', 'h5', 'h6']
                .contains(node.localName)
        ? '$content\n'
        : content;
  }

  static final _emergency = RegExp(
      r'(?:екстрен[а-яіїєґ]*|аварійн[а-яіїєґ]*)(?:\s+(?:відключен|вимкнен|знеструмлен)[а-яіїєґ]*)?');
  static const _cancellationWords =
      r'(?:скасован[а-яіїєґ]*|скасовано|відмінен[а-яіїєґ]*|відмінено|припинен[а-яіїєґ]*|припинено|не діють|не застосовуються|не застосовують|не вводяться|не запроваджуються|не введен[а-яіїєґ]*|не запроваджен[а-яіїєґ]*|немає|відсутн[а-яіїєґ]*)';
  static const _cancellationFiller =
      r'(?:(?:електроенергії|вже|були|наразі|більше)\s+)*';
  static final _cancelled =
      RegExp('$_cancellationWords\\s+$_cancellationFiller${_emergency.pattern}|'
          '${_emergency.pattern}\\s+$_cancellationFiller$_cancellationWords');
  static final _hypothetical =
      RegExp(r'якщо|у разі|уникн|запобіг|не допуст|недопущ|будуть');
  static final _standard = RegExp(
      r'(?:введені|введено|запроваджені|запроваджено|застосовуються|діють)\s+екстрені відключення|екстрені відключення\s+(?:введені|введено|запроваджені|запроваджено|діють|застосовуються)');
  static final _local =
      RegExp(r'район|частин|окрем|громад|населен|вулиц|адрес|локаль');

  static final _whole = RegExp(
      r'(?:всій|усій|всю|усю)\s+област|(?:всіх|усіх)\s+(?:район|громад)');
  static final _uncertain = RegExp(r'можлив|можуть|може');

  static bool? parse(String html) => parseObservation(html, 1)?.active;

  /// A readable operational modal is evidence even when its wording changes.
  /// A challenge, empty modal or incomplete page is still unknown.
  static EmergencyObservation? parseObservation(String html, int observedAt) {
    if (html.isEmpty ||
        RegExp(r'_Incapsula_Resource|cf-browser-verification|Just a moment\.\.\.')
            .hasMatch(html)) {
      return null;
    }
    final document = html_parser.parse(html);
    final notices = document
        .querySelectorAll('#modal-attention, .m-attention, .modal-attention')
        .where((notice) => !_insideIgnoredElement(notice))
        .toList();
    final states = <bool>{};
    var possible = false;
    final texts = <String>{};
    for (final notice in notices) {
      final source = _text(notice)
          .split('\n')
          .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((line) => line.isNotEmpty)
          .join('\n\n');
      if (source.isEmpty) continue;
      texts.add(source);
      final text = source
          .toLowerCase()
          .replaceAll('i', 'і')
          .replaceAll(RegExp(r'\s+'), ' ');
      var hasEmergency = false;
      for (final part in text.split(RegExp(r'[.!?;]'))) {
        final sentence = part.replaceAll(_cancelled, '');
        if (!_emergency.hasMatch(sentence) ||
            _hypothetical.hasMatch(sentence)) {
          continue;
        }
        hasEmergency = true;
        possible |= !_standard.hasMatch(sentence) ||
            _uncertain.hasMatch(sentence) ||
            (_local.hasMatch(sentence) && !_whole.hasMatch(sentence));
      }
      // Cancellation of global restrictions can coexist with a local accident.
      if (hasEmergency) {
        states.add(true);
      } else {
        states.add(false);
      }
    }
    if (states.length == 1) {
      return EmergencyObservation(states.single, observedAt,
          confirmed: true,
          isPossible: states.single && possible,
          noticeText: texts.join('\n\n'));
    }
    if (states.isNotEmpty || notices.isNotEmpty) return null;
    // A script-only bridge, a login page and incomplete HTML are not evidence
    // of cancellation. Require a complete recognizable DTEK schedule page.
    final complete =
        RegExp(r'<html(?:\s|>)', caseSensitive: false).hasMatch(html) &&
            RegExp(r'<body(?:\s|>)', caseSensitive: false).hasMatch(html) &&
            RegExp(r'</body\s*>', caseSensitive: false).hasMatch(html) &&
            RegExp(r'</html\s*>', caseSensitive: false).hasMatch(html) &&
            RegExp(r'DisconSchedule\.fact\s*=').hasMatch(html);
    return complete
        ? EmergencyObservation(false, observedAt, confirmed: true)
        : null;
  }
}
