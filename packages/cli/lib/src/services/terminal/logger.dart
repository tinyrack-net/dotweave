// Dart port of `packages/cli/src/services/terminal/logger.ts`.

import 'dart:io' as io;

import 'package:dotweave/src/services/terminal/spinner.dart';
import 'package:dotweave/src/services/terminal/theme.dart';

/// Mirror of the TS `CliLogger` interface.
abstract class CliLogger {
  void log(String message);
  void info(String message);
  void success(String message);
  void fail(String message);
  void warn(String message);
  void error(String message);
  void start(String message);

  void section(String title);

  /// Render a key/value pair aligned to the configured label width.
  void kv(String key, String value);

  /// Render each item as a list entry using optional bullet and optional
  /// last-item highlight.
  void list(List<String> items, {String? bullet, bool? highlightLast});

  /// Render key/value pairs as aligned list lines, preserving empty-value
  /// keys.
  void listKeyValue(List<({String key, String? value})> items);

  /// Render a visual divider line.
  void divider();

  /// Start and return a spinner bound to stdout for long-running operations.
  Spinner spinner(String text);
}

/// Mirror of the TS `Stream` type:
/// `Pick<NodeJS.WriteStream, "write" | "isTTY" | "clearLine" | "cursorTo">`.
abstract class Stream {
  bool get isTTY;
  void write(String chunk);
  void clearLine(int dir);
  void cursorTo(int column);
}

/// Adapts a `dart:io` [io.Stdout] to the Node write-stream surface, emitting
/// the same ANSI sequences Node's `clearLine`/`cursorTo` write.
class _StdioStream implements Stream {
  _StdioStream(this._sink);

  final io.Stdout _sink;

  @override
  bool get isTTY => _sink.hasTerminal;

  @override
  void write(String chunk) {
    _sink.write(chunk);
  }

  @override
  void clearLine(int dir) {
    _sink.write(
      dir < 0
          ? '\x1B[1K'
          : dir > 0
          ? '\x1B[0K'
          : '\x1B[2K',
    );
  }

  @override
  void cursorTo(int column) {
    _sink.write('\x1B[${column + 1}G');
  }
}

const String _INDENT = '  '; // ignore: constant_identifier_names

ColorTheme _defaultColorTheme() => color;

Spinner _defaultCreateSpinner(Stream stream, String text) =>
    createSpinner(stream, text);

class _CliLogger implements CliLogger {
  _CliLogger({
    required this.stdout,
    required this.stderr,
    required this.prefix,
    required this.color,
    required this.symbols,
    required this.createSpinnerFn,
  });

  final Stream stdout;
  final Stream stderr;
  final String prefix;
  final ColorTheme color;
  final Symbols symbols;
  final Spinner Function(Stream stream, String text) createSpinnerFn;

  /// Single write helper for all stdout/stderr output paths.
  void _w(Stream dest, String msg) {
    dest.write('$prefix$msg\n');
  }

  @override
  void log(String message) => _w(stdout, message);

  @override
  void info(String message) =>
      _w(stdout, '${color.info(symbols.info)} $message');

  @override
  void success(String message) =>
      _w(stdout, '${color.success(symbols.success)} $message');

  @override
  void fail(String message) =>
      _w(stdout, '${color.error(symbols.error)} $message');

  @override
  void warn(String message) =>
      _w(stderr, '${color.warn(symbols.warn)} $message');

  @override
  void error(String message) =>
      _w(stderr, '${color.error(symbols.error)} $message');

  @override
  void start(String message) =>
      _w(stdout, '${color.info(symbols.bullet)} ${color.dim(message)}');

  @override
  void section(String title) {
    _w(stdout, '');
    _w(stdout, color.bold(title));
  }

  @override
  void kv(String key, String value) {
    _w(stdout, '$_INDENT${color.label(key)}: $value');
  }

  @override
  void list(List<String> items, {String? bullet, bool? highlightLast}) {
    final bulletValue = bullet ?? '-';
    for (var i = 0; i < items.length; i++) {
      final isLast = i == items.length - 1;
      final highlight = highlightLast == true && isLast;
      final line = '$_INDENT$bulletValue ${items[i]}';
      _w(stdout, highlight ? color.highlight(line) : line);
    }
  }

  @override
  void listKeyValue(List<({String key, String? value})> items) {
    var maxKeyLen = 0;
    for (final item in items) {
      if (item.key.length > maxKeyLen) {
        maxKeyLen = item.key.length;
      }
    }
    for (final item in items) {
      final paddedKey = item.key.padRight(maxKeyLen);
      final value = item.value;
      if (value != null) {
        _w(stdout, '$_INDENT${color.label(paddedKey)}  $value');
      } else {
        _w(stdout, '$_INDENT${color.label(item.key)}');
      }
    }
  }

  @override
  void divider() {
    _w(stdout, color.dim('————————————————'));
  }

  @override
  Spinner spinner(String text) {
    return createSpinnerFn(stdout, text);
  }
}

/// Build a logger with optional stream overrides and optional prefix tag.
/// Tag is only cosmetic and prepends a dim "[tag]" prefix to every output
/// line. The optional [color]/[symbols]/[createSpinner] overrides are the DI
/// seams replacing the vitest module mocks of `./theme.ts` and
/// `./spinner.ts`.
CliLogger createCliLogger({
  Stream? stderr,
  Stream? stdout,
  String? tag,
  ColorTheme? color,
  Symbols? symbols,
  Spinner Function(Stream stream, String text)? createSpinner,
}) {
  // Default to process streams when callers don't pass explicit destination
  // streams.
  final stdoutStream = stdout ?? _StdioStream(io.stdout);
  final stderrStream = stderr ?? _StdioStream(io.stderr);
  final prefix = tag == null ? '' : pc.dim('[$tag] ');

  // Core logger surface used across commands; each method formats
  // consistently.
  return _CliLogger(
    stdout: stdoutStream,
    stderr: stderrStream,
    prefix: prefix,
    color: color ?? _defaultColorTheme(),
    symbols: symbols ?? SYMBOLS,
    createSpinnerFn: createSpinner ?? _defaultCreateSpinner,
  );
}
