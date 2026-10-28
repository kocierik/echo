import 'package:echo_app/utils/spoken_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('markdown marks and links are not read out', () {
    const answer = '## Domani a Milano\n'
        '**Pioggia** dalle 15, porta l\'ombrello.\n'
        '- Minima `12 °C`\n'
        '• Massima 18 °C\n'
        'Fonte: [Meteo.it](https://meteo.it/milano) e https://ilmeteo.it/x?y=1';

    expect(
      spokenText(answer, language: 'it'),
      'Domani a Milano\n'
      'Pioggia dalle 15, porta l\'ombrello.\n'
      'Minima 12 °C\n'
      'Massima 18 °C\n'
      'Fonte: Meteo.it e',
    );
  });

  test('a long answer is cut at a sentence end, then says the rest is in Ask', () {
    const sentence = 'Tomorrow it rains in Milan from three in the afternoon. ';
    final answer = sentence * 20;

    final spoken = spokenText(answer, language: 'en');

    expect(spoken.length, lessThanOrEqualTo(500 + ' The rest is in Ask.'.length));
    expect(spoken, endsWith('afternoon. The rest is in Ask.'));
  });

  test('without a sentence end it is cut at a word; Italian says so in Italian', () {
    final answer = 'parola ' * 120;

    final spoken = spokenText(answer, language: 'it');

    expect(spoken, endsWith('parola… Il resto è in Ask.'));
  });

  test('a short answer is read whole', () {
    expect(spokenText('Sì, alle 15.', language: 'it'), 'Sì, alle 15.');
  });
}
