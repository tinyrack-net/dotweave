import 'dart:math' as math;

/// Limits the number of concurrent asynchronous operations.
///
/// Port of `lib/promise.ts` `limitConcurrency`: a pool of at most
/// [concurrency] workers drains [items] in order and results keep the input
/// index order.
/// Throws [ArgumentError] when [concurrency] is below 1, which would otherwise
/// spawn zero workers and silently return a list of nulls.
Future<List<R>> limitConcurrency<T, R>(
  int concurrency,
  List<T> items,
  Future<R> Function(T item, int index) mapper,
) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }

  // Grown in index order by the workers below, so no nullable placeholder and
  // no unsound cast back to R is needed.
  final results = <int, R>{};
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

  return [for (var i = 0; i < items.length; i += 1) results[i] as R];
}
