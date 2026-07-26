import 'package:test/test.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

// These helpers are public API and are what a user actually sees when they
// mistype something: the did-you-mean engine, the help column layout, and the
// scanner error wording. Getting them wrong produces bad output rather than a
// crash, so nothing else in the suite would notice. Until now they were only
// covered indirectly, through end-to-end runs of a whole application.

void main() {
  group('damerauLevenshtein', () {
    final options = defaultDistanceOptions;

    test('is zero for identical strings', () {
      expect(damerauLevenshtein('status', 'status', options), 0);
    });

    test('charges each edit kind its configured weight', () {
      // The defaults are deliberately lopsided (deletion 3, insertion 1,
      // substitution 2): a user who typed too few characters is likelier to
      // have meant the longer command than the other way round.
      expect(
        damerauLevenshtein('status', 'statu', options),
        3,
        reason: 'deletion',
      );
      expect(
        damerauLevenshtein('statu', 'status', options),
        1,
        reason: 'insertion',
      );
      expect(
        damerauLevenshtein('status', 'statux', options),
        2,
        reason: 'substitution',
      );
    });

    test('is asymmetric, because insertion and deletion differ', () {
      // d(a, b) != d(b, a). Callers must pass the user's input as `a` and the
      // known command as `b`, or suggestions get noticeably worse.
      expect(damerauLevenshtein('statu', 'status', options), 1);
      expect(damerauLevenshtein('status', 'statu', options), 3);
    });

    test('treats a transposition as free', () {
      // transposition weight is 0 by default, so two strings that differ only
      // by swapped adjacent characters score 0 — the same as equality. This is
      // the point of the Damerau variant: swapped keys are the most common
      // typo and should always win the suggestion.
      expect(damerauLevenshtein('status', 'sttaus', options), 0);
      expect(damerauLevenshtein('push', 'psuh', options), 0);
    });

    test('returns infinity past the threshold instead of the real distance', () {
      // The early exit is an optimization, and it changes the return value, so
      // callers must compare against the threshold rather than trust the number.
      const tight = DistanceOptions(
        threshold: 2,
        weights: DistanceWeights(
          insertion: 1,
          deletion: 1,
          substitution: 1,
          transposition: 1,
        ),
      );

      expect(damerauLevenshtein('a', 'abcdefgh', tight), double.infinity);
      expect(damerauLevenshtein('ab', 'abc', tight), 1);
    });

    test('applies the configured weights', () {
      const insertionIsExpensive = DistanceOptions(
        threshold: 10,
        weights: DistanceWeights(
          insertion: 5,
          deletion: 1,
          substitution: 1,
          transposition: 1,
        ),
      );

      expect(damerauLevenshtein('ab', 'abc', insertionIsExpensive), 5);
      expect(damerauLevenshtein('abc', 'ab', insertionIsExpensive), 1);
    });
  });

  group('filterClosestAlternatives', () {
    final options = defaultDistanceOptions;

    test('suggests the near miss and drops the unrelated ones', () {
      expect(
        filterClosestAlternatives('statsu', [
          'status',
          'track',
          'untrack',
        ], options),
        ['status'],
      );
    });

    test(
      'keeps only the joint-closest candidates, not everything in range',
      () {
        // `pull` and `push` are both distance 1; `profile` is further away and
        // must not ride along just because it is under the threshold.
        expect(
          filterClosestAlternatives('pul', [
            'pull',
            'push',
            'profile',
          ], options),
          ['pull'],
        );
      },
    );

    test('prefers a prefix match when distances tie', () {
      // Tie-break order is observable in the "did you mean" line, so it is
      // part of the contract rather than an implementation detail.
      expect(filterClosestAlternatives('pus', ['opus', 'push'], options), [
        'push',
        'opus',
      ]);
    });

    test('sorts alphabetically when distance and prefix both tie', () {
      expect(filterClosestAlternatives('ab', ['zb', 'bb', 'mb'], options), [
        'bb',
        'mb',
        'zb',
      ]);
    });

    test('returns nothing when every alternative is past the threshold', () {
      const tight = DistanceOptions(
        threshold: 1,
        weights: DistanceWeights(
          insertion: 1,
          deletion: 1,
          substitution: 1,
          transposition: 1,
        ),
      );

      expect(
        filterClosestAlternatives('xyz', ['status', 'track'], tight),
        isEmpty,
      );
    });

    test('handles an empty alternative list', () {
      expect(filterClosestAlternatives('status', const [], options), isEmpty);
    });
  });

  group('formatRowsWithColumns', () {
    test('pads every column to the widest cell', () {
      expect(
        formatRowsWithColumns([
          ['a', 'first'],
          ['bbb', 'second'],
        ]),
        ['a   first', 'bbb second'],
      );
    });

    test('does not pad a column that some row omits', () {
      // Only the trailing column is ragged here, so columns 0 and 1 still pad
      // to width 2 while column 2 is left alone. Mirrors the JS
      // `Math.max(len, undefined) -> NaN -> padEnd(NaN)` behaviour.
      expect(
        formatRowsWithColumns([
          ['a', 'b', 'c'],
          ['dd', 'ee'],
        ]),
        ['a  b  c', 'dd ee'],
      );
    });

    test('uses the supplied separators between columns', () {
      expect(
        formatRowsWithColumns(
          [
            ['a', 'b', 'c'],
            ['aa', 'bb', 'cc'],
          ],
          ['  ', ' -- '],
        ),
        ['a   b  -- c', 'aa  bb -- cc'],
      );
    });

    test('returns nothing for no rows', () {
      expect(formatRowsWithColumns(const []), isEmpty);
    });
  });

  group('joinWithGrammar', () {
    test('joins two parts without a comma', () {
      expect(
        joinWithGrammar(['a', 'b'], conjunction: 'or', serialComma: true),
        'a or b',
      );
    });

    test('adds the serial comma only when asked', () {
      expect(
        joinWithGrammar(['a', 'b', 'c'], conjunction: 'and', serialComma: true),
        'a, b, and c',
      );
      expect(
        joinWithGrammar(
          ['a', 'b', 'c'],
          conjunction: 'and',
          serialComma: false,
        ),
        'a, b and c',
      );
    });

    test('passes through zero and one part', () {
      expect(joinWithGrammar([], conjunction: 'or', serialComma: true), '');
      expect(
        joinWithGrammar(['only'], conjunction: 'or', serialComma: true),
        'only',
      );
    });
  });

  group('value parsers', () {
    test('booleanParser accepts only true/false, case-insensitively', () {
      expect(booleanParser('true'), isTrue);
      expect(booleanParser('FALSE'), isFalse);
      expect(() => booleanParser('yes'), throwsFormatException);
      expect(() => booleanParser(''), throwsFormatException);
    });

    test('looseBooleanParser accepts the shell-ish spellings', () {
      for (final input in ['true', 't', 'yes', 'y', 'on', '1', '']) {
        expect(looseBooleanParser(input), isTrue, reason: input);
      }
      for (final input in ['false', 'f', 'no', 'n', 'off', '0']) {
        expect(looseBooleanParser(input), isFalse, reason: input);
      }
      expect(() => looseBooleanParser('maybe'), throwsFormatException);
    });

    test('an empty string is truthy loosely but invalid strictly', () {
      // `--flag=` with no value means "on" for a loose flag; the strict parser
      // rejects it. Pinned because the asymmetry is easy to "fix" by accident.
      expect(looseBooleanParser(''), isTrue);
      expect(() => booleanParser(''), throwsFormatException);
    });

    test('numberParser accepts ints, decimals, and signs', () {
      expect(numberParser('42'), 42);
      expect(numberParser('-1.5'), -1.5);
      expect(() => numberParser('12abc'), throwsFormatException);
      expect(() => numberParser(''), throwsFormatException);
    });
  });

  group('formatMessageForArgumentScannerError', () {
    test('uses the override registered for the error type', () {
      final error = FlagNotFoundError('--nope', const ['--note']);

      expect(
        formatMessageForArgumentScannerError(error, {
          'FlagNotFoundError': (e) => 'custom: ${e.message}',
        }),
        startsWith('custom: '),
      );
    });

    test('falls back to the error message when no override matches', () {
      final error = FlagNotFoundError('--nope', const []);

      expect(
        formatMessageForArgumentScannerError(error, const {}),
        error.message,
      );
      expect(
        formatMessageForArgumentScannerError(error, {
          'SomeOtherError': (e) => 'unused',
        }),
        error.message,
      );
    });

    test('the default message names the input and its suggestions', () {
      final error = FlagNotFoundError('--stats', const ['--status']);

      expect(error.message, contains('--stats'));
      expect(error.message, contains('--status'));
    });
  });
}
