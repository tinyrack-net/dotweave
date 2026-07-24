import 'dart:math' as math;

/// Limits the number of concurrent asynchronous operations.
///
/// Port of `lib/promise.ts` `limitConcurrency`: a pool of at most
/// [concurrency] workers drains [items] in order and results keep the input
/// index order.
Future<List<R>> limitConcurrency<T, R>(
  int concurrency,
  List<T> items,
  Future<R> Function(T item, int index) mapper,
) async {
  final results = List<R?>.filled(items.length, null);
  var currentIndex = 0;

  Future<void> worker() async {
    while (currentIndex < items.length) {
      final index = currentIndex;
      currentIndex += 1;
      results[index] = await mapper(items[index], index);
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(concurrency, items.length); i += 1) worker(),
  ]);

  return [for (final result in results) result as R];
}
