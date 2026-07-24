import 'package:dotweave/src/lib/error.dart';
import 'package:test/test.dart';

void main() {
  group('dotweave error helpers', () {
    test('formats strings and plain errors without extra decoration', () {
      expect(formatDotweaveError('plain message'), 'plain message');
      expect(formatDotweaveError(Exception('broken')), 'broken');
    });

    test(
      'formats DotweaveError details and hints while removing empty lines',
      () {
        final error = DotweaveError(
          'Unable to sync',
          details: ['first detail', '', '   ', 'second detail'],
          hint: 'Run dotweave doctor.',
        );

        expect(
          formatDotweaveError(error),
          'Unable to sync\nfirst detail\nsecond detail\n→ Run dotweave doctor.',
        );
      },
    );

    test('wraps unknown errors while preserving provided metadata', () {
      final wrapped = wrapUnknownError(
        'Failed to pull',
        Exception(' timeout '),
        code: 'PULL_FAILED',
        details: ['existing detail'],
        hint: 'Try again.',
      );

      expect(wrapped, isA<DotweaveError>());
      expect(wrapped.code, 'PULL_FAILED');
      expect(wrapped.hint, 'Try again.');
      expect(wrapped.message, 'Failed to pull');
      expect(wrapped.details, ['existing detail', 'timeout']);
    });

    test('stringifies non-Error values when wrapping unknown failures', () {
      final wrapped = wrapUnknownError('Failed to parse', {'code': 123});

      expect(wrapped.details, ['{code: 123}']);
    });
  });
}
