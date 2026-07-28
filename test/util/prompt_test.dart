import 'package:dotweave/src/util/prompt.dart';
import 'package:test/test.dart';

class _MockReadlineInterface implements ReadlineInterface {
  Future<String> Function(String question)? questionHandler;
  final List<String> questionCalls = [];
  int closeCalls = 0;

  @override
  Future<String> question(String query) {
    questionCalls.add(query);
    final handler = questionHandler;
    if (handler == null) {
      throw StateError('questionHandler not set');
    }
    return handler(query);
  }

  @override
  void close() {
    closeCalls++;
  }
}

void main() {
  group('prompt', () {
    late _MockReadlineInterface mockCreateInterface;

    setUp(() {
      mockCreateInterface = _MockReadlineInterface();
    });

    test('returns the answer from readline', () async {
      mockCreateInterface.questionHandler = (_) async => 'yes';

      final result = await ask(
        'Continue? ',
        createInterface: () => mockCreateInterface,
      );

      expect(result, 'yes');
      expect(mockCreateInterface.questionCalls, contains('Continue? '));
      expect(mockCreateInterface.closeCalls, greaterThan(0));
    });

    test('closes readline even when question rejects', () async {
      mockCreateInterface.questionHandler = (_) =>
          Future<String>.error(Exception('interrupted'));

      await expectLater(
        ask('Continue? ', createInterface: () => mockCreateInterface),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('interrupted'),
          ),
        ),
      );
      expect(mockCreateInterface.closeCalls, greaterThan(0));
    });

    test('returns empty string when user provides no input', () async {
      mockCreateInterface.questionHandler = (_) async => '';

      final result = await ask(
        'Continue? ',
        createInterface: () => mockCreateInterface,
      );

      expect(result, '');
      expect(mockCreateInterface.closeCalls, greaterThan(0));
    });

    test('handles multiple sequential ask calls', () async {
      final answers = ['a1', 'a2'];
      var callIndex = 0;
      mockCreateInterface.questionHandler = (_) async => answers[callIndex++];

      final r1 = await ask('Q1? ', createInterface: () => mockCreateInterface);
      final r2 = await ask('Q2? ', createInterface: () => mockCreateInterface);

      expect(r1, 'a1');
      expect(r2, 'a2');
      expect(mockCreateInterface.questionCalls, contains('Q1? '));
      expect(mockCreateInterface.questionCalls, contains('Q2? '));
      expect(mockCreateInterface.closeCalls, 2);
    });

    test('handles special characters in question prompts', () async {
      mockCreateInterface.questionHandler = (_) async => 'val';

      await ask(
        'Enter value for --flag: ',
        createInterface: () => mockCreateInterface,
      );

      expect(
        mockCreateInterface.questionCalls,
        contains('Enter value for --flag: '),
      );
    });

    test(
      'calls close for every ask call regardless of question result',
      () async {
        mockCreateInterface.questionHandler = (_) async => 'ok';

        await ask('Q1? ', createInterface: () => mockCreateInterface);
        await ask('Q2? ', createInterface: () => mockCreateInterface);
        await ask('Q3? ', createInterface: () => mockCreateInterface);

        expect(mockCreateInterface.closeCalls, 3);
      },
    );
  });
}
