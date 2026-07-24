// Temporary, env-gated phase timing for performance diagnosis.
//
// Enabled only when DOTWEAVE_PERF_TRACE=1; completely inert otherwise (a
// single map lookup at import-cost). Aggregates wall-clock per labeled phase
// and dumps a table to stderr when [dumpPerfTrace] is called. Not part of
// the behavioral surface — remove or keep dormant once the investigation
// concludes.

import 'dart:io';

final bool perfTraceEnabled =
    Platform.environment['DOTWEAVE_PERF_TRACE'] == '1';

final Map<String, int> _totalsMicros = <String, int>{};
final Map<String, int> _counts = <String, int>{};

/// Times [action] under [label] when tracing is enabled; zero overhead
/// otherwise beyond the boolean check.
Future<T> tracePhase<T>(String label, Future<T> Function() action) async {
  if (!perfTraceEnabled) {
    return action();
  }

  final stopwatch = Stopwatch()..start();
  try {
    return await action();
  } finally {
    stopwatch.stop();
    _totalsMicros[label] =
        (_totalsMicros[label] ?? 0) + stopwatch.elapsedMicroseconds;
    _counts[label] = (_counts[label] ?? 0) + 1;
  }
}

/// Dumps the aggregated phase table to stderr and resets the counters.
void dumpPerfTrace(String header) {
  if (!perfTraceEnabled || _totalsMicros.isEmpty) {
    return;
  }

  stderr.writeln('[perf] $header');
  final labels = _totalsMicros.keys.toList()..sort();
  for (final label in labels) {
    final totalMs = (_totalsMicros[label]! / 1000).toStringAsFixed(1);
    final count = _counts[label]!;
    final perOp = (_totalsMicros[label]! / count).toStringAsFixed(1);
    stderr.writeln(
      '[perf]   ${label.padRight(32)} total ${totalMs.padLeft(10)} ms  '
      'n=${count.toString().padLeft(6)}  ${perOp.padLeft(9)} us/op',
    );
  }
  _totalsMicros.clear();
  _counts.clear();
}
