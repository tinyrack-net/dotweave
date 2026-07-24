import 'package:dotweave/src/lib/string.dart';
import 'package:test/test.dart';

void main() {
  group('string helpers', () {
    test('adds a trailing newline when missing', () {
      expect(ensureTrailingNewline('value'), 'value\n');
    });

    test('preserves an existing trailing newline', () {
      expect(ensureTrailingNewline('value\n'), 'value\n');
    });

    test(
      'normalizeConfiguredValue trims whitespace from a non-empty string',
      () {
        expect(normalizeConfiguredValue('  hello  '), 'hello');
      },
    );

    test('normalizeConfiguredValue returns null for null input', () {
      expect(normalizeConfiguredValue(null), isNull);
    });

    test('normalizeConfiguredValue returns null for an empty string', () {
      expect(normalizeConfiguredValue(''), isNull);
    });

    test(
      'normalizeConfiguredValue returns null for a whitespace-only string',
      () {
        expect(normalizeConfiguredValue('   '), isNull);
      },
    );

    test(
      'normalizeConfiguredValue returns a trimmed string for padded input',
      () {
        expect(normalizeConfiguredValue('\tvalue\t'), 'value');
      },
    );
  });
}
