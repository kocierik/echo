import 'package:echo_app/services/app/spoken_answers_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('off until chosen; a stored choice is read back', () async {
    SharedPreferences.setMockInitialValues({});
    expect(SpokenAnswersStore(await SharedPreferences.getInstance()).value, SpokenAnswers.off);

    SharedPreferences.setMockInitialValues({SpokenAnswersStore.key: 'headphones'});
    expect(
      SpokenAnswersStore(await SharedPreferences.getInstance()).value,
      SpokenAnswers.headphones,
    );
  });

  test('an unknown stored value is off', () async {
    SharedPreferences.setMockInitialValues({SpokenAnswersStore.key: 'loud'});
    expect(SpokenAnswersStore(await SharedPreferences.getInstance()).value, SpokenAnswers.off);
  });

  test('a choice is saved and heard', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = SpokenAnswersStore(preferences);
    final heard = <SpokenAnswers>[];
    store.addListener(() => heard.add(store.value));

    await store.set(SpokenAnswers.always);

    expect(heard, [SpokenAnswers.always]);
    expect(preferences.getString(SpokenAnswersStore.key), 'always');
  });
}
