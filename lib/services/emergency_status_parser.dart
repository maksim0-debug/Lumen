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
        ['script', 'style', 'template', 'noscript'].contains(node.localName)) {
      return '';
    }
    return node.nodes.map(_text).join(' ');
  }

  static bool? parse(String html) {
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
    for (final notice in notices) {
      final text = _text(notice)
          .toLowerCase()
          .replaceAll('i', 'і')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      for (final sentence in text.split(RegExp(r'[.!?;]'))) {
        if (RegExp(r'якщо|у разі|можуть|можлив|будуть|не введен|не запроваджен')
            .hasMatch(sentence)) {
          continue;
        }
        if (RegExp(
                r'екстрені відключення\s+(?:скасовано|скасовані|припинено|не діють|не застосовуються)|(?:скасовано|скасовані|припинено|не діють|не застосовуються)\s+екстрені відключення')
            .hasMatch(sentence)) {
          states.add(false);
          continue;
        }
        if (RegExp(
                r'(?:введені|введено|запроваджені|запроваджено|застосовуються|діють)\s+екстрені відключення|екстрені відключення\s+(?:введені|введено|запроваджені|запроваджено|діють|застосовуються)')
            .hasMatch(sentence)) {
          states.add(true);
        }
      }
    }
    if (states.length == 1) return states.single;
    if (states.isNotEmpty || notices.isNotEmpty) return null;
    // A script-only bridge, a login page and incomplete HTML are not evidence
    // of cancellation. Require a complete recognizable DTEK schedule page.
    final complete =
        RegExp(r'<html(?:\s|>)', caseSensitive: false).hasMatch(html) &&
            RegExp(r'<body(?:\s|>)', caseSensitive: false).hasMatch(html) &&
            RegExp(r'</body\s*>', caseSensitive: false).hasMatch(html) &&
            RegExp(r'</html\s*>', caseSensitive: false).hasMatch(html) &&
            RegExp(r'DisconSchedule\.fact\s*=').hasMatch(html);
    return complete ? false : null;
  }
}
