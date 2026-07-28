import 'package:dotweave/src/util/concurrency.dart';
import 'package:test/test.dart';

void main() {
  group('limitConcurrency', () {
    test('maps items correctly', () async {
      final items = [1, 2, 3, 4, 5];
      var calls = 0;

      final results = await limitConcurrency(2, items, (item, _) async {
        calls += 1;
        return item * 2;
      });

      expect(results, [2, 4, 6, 8, 10]);
      expect(calls, 5);
    });

    test('limits concurrency', () async {
      final items = [1, 2, 3, 4, 5];
      var activeCount = 0;
      var maxActiveCount = 0;

      await limitConcurrency(2, items, (_, _) async {
        activeCount += 1;
        maxActiveCount = maxActiveCount > activeCount
            ? maxActiveCount
            : activeCount;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        activeCount -= 1;
      });

      expect(maxActiveCount, lessThanOrEqualTo(2));
    });

    test('passes correct indices to the mapper', () async {
      final items = ['a', 'b', 'c'];
      final indices = <int>[];

      await limitConcurrency(2, items, (_, index) async {
        indices.add(index);
      });

      expect(indices..sort(), [0, 1, 2]);
    });

    test('handles empty arrays', () async {
      final results = await limitConcurrency(2, <int>[], (_, _) async {
        return 'never';
      });
      expect(results, isEmpty);
    });

    test('handles concurrency greater than item count', () async {
      final items = [1, 2];
      final results = await limitConcurrency(10, items, (item, _) async {
        return item;
      });
      expect(results, [1, 2]);
    });

    test(
      'rejects a concurrency below 1 instead of spawning no workers',
      () async {
        // A non-positive concurrency used to produce zero workers, leaving every
        // slot unwritten and surfacing as a cast failure on the way out.
        for (final concurrency in [0, -1]) {
          await expectLater(
            limitConcurrency(concurrency, [1, 2, 3], (item, _) async => item),
            throwsA(isA<ArgumentError>()),
          );
        }
      },
    );

    test('propagates errors', () async {
      final items = [1, 2, 3];

      await expectLater(
        limitConcurrency(2, items, (item, _) async {
          if (item == 2) {
            throw Exception('fail');
          }
          return item;
        }),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('fail'),
          ),
        ),
      );
    });
  });
}
