// Dart port of `packages/cli/src/services/terminal/theme.ts`.
//
// The TS module wraps the npm `picocolors` package. Dart has no picocolors,
// so this file also ports the subset of picocolors@1.1.1 the CLI uses
// (bold, dim, red, green, yellow, cyan) verbatim: the same enablement
// expression, the exact ANSI escape sequences, and the nested-reset
// `replaceClose` behavior.

// ignore_for_file: constant_identifier_names

import 'dart:io';

import 'package:dotweave/src/util/env.dart';

/// Mirrors NodeJS `process.platform` for the values picocolors checks.
String _processPlatform() {
  if (Platform.isWindows) {
    return 'win32';
  }
  if (Platform.isMacOS) {
    return 'darwin';
  }
  return Platform.operatingSystem;
}

/// JS truthiness for environment values: defined and non-empty.
bool _isTruthyEnvValue(String? value) {
  return value != null && value.isNotEmpty;
}

/// picocolors' module-level `isColorSupported` expression: color is enabled
/// unless `NO_COLOR`/`--no-color` disables it, and one of `FORCE_COLOR`,
/// `--color`, win32, an interactive non-dumb terminal, or `CI` enables it.
///
/// Node reads `process.argv`; Dart has no global argv, so [argv] defaults to
/// an empty list (the dotweave CLI never passes `--color`/`--no-color`).
bool resolveIsColorSupported({
  Env? env,
  List<String> argv = const [],
  String? platform,
  bool? stdoutIsTTY,
}) {
  final environment = env ?? ENV;
  final platformName = platform ?? _processPlatform();
  final isTTY = stdoutIsTTY ?? stdout.hasTerminal;

  return !(_isTruthyEnvValue(environment['NO_COLOR']) ||
          argv.contains('--no-color')) &&
      (_isTruthyEnvValue(environment['FORCE_COLOR']) ||
          argv.contains('--color') ||
          platformName == 'win32' ||
          (isTTY && environment['TERM'] != 'dumb') ||
          _isTruthyEnvValue(environment['CI']));
}

/// picocolors' `replaceClose`: rewrites nested close sequences so wrapping a
/// pre-colored string re-opens the outer style after each inner reset.
String _replaceClose(String string, String close, String replace, int index) {
  var result = '';
  var cursor = 0;
  var closeIndex = index;

  do {
    result += string.substring(cursor, closeIndex) + replace;
    cursor = closeIndex + close.length;
    closeIndex = string.indexOf(close, cursor);
  } while (closeIndex >= 0);

  return result + string.substring(cursor);
}

/// picocolors' `formatter`: wraps input in open/close sequences, applying
/// [_replaceClose] when the input already contains the close sequence.
String Function(String input) _formatter(
  String open,
  String close, [
  String? replace,
]) {
  final replaceValue = replace ?? open;

  return (String input) {
    // JS `indexOf(close, open.length)` tolerates a start beyond the string
    // end; Dart throws, so guard explicitly.
    final index = open.length > input.length
        ? -1
        : input.indexOf(close, open.length);

    return index >= 0
        ? open + _replaceClose(input, close, replaceValue, index) + close
        : open + input + close;
  };
}

/// Disabled formatter, mirroring picocolors' `() => String` identity.
String _identity(String input) => input;

/// The subset of picocolors' color functions used by the dotweave CLI.
class Picocolors {
  Picocolors._(
    this.isColorSupported,
    this._bold,
    this._dim,
    this._red,
    this._green,
    this._yellow,
    this._cyan,
  );

  final bool isColorSupported;
  final String Function(String input) _bold;
  final String Function(String input) _dim;
  final String Function(String input) _red;
  final String Function(String input) _green;
  final String Function(String input) _yellow;
  final String Function(String input) _cyan;

  String bold(String input) => _bold(input);
  String dim(String input) => _dim(input);
  String red(String input) => _red(input);
  String green(String input) => _green(input);
  String yellow(String input) => _yellow(input);
  String cyan(String input) => _cyan(input);
}

final bool _defaultIsColorSupported = resolveIsColorSupported();

/// picocolors' `createColors`, defaulting enablement to the module-level
/// support detection.
Picocolors createColors({bool? enabled}) {
  final isEnabled = enabled ?? _defaultIsColorSupported;

  String Function(String input) f(
    String open,
    String close, [
    String? replace,
  ]) {
    return isEnabled ? _formatter(open, close, replace) : _identity;
  }

  return Picocolors._(
    isEnabled,
    f('\x1B[1m', '\x1B[22m', '\x1B[22m\x1B[1m'),
    f('\x1B[2m', '\x1B[22m', '\x1B[22m\x1B[2m'),
    f('\x1B[31m', '\x1B[39m'),
    f('\x1B[32m', '\x1B[39m'),
    f('\x1B[33m', '\x1B[39m'),
    f('\x1B[36m', '\x1B[39m'),
  );
}

/// The default picocolors instance, mirroring `import pc from "picocolors"`.
final Picocolors pc = createColors();

Picocolors _resolvePicocolors(Picocolors? override) => override ?? pc;

/// Mirror of the TS `SYMBOLS` const object.
class Symbols {
  const Symbols();

  final String success = '✔';
  final String error = '✖';
  final String warn = '⚠';
  final String info = '~';
  final String add = '+';
  final String modify = '~';
  final String delete = '-';
  final String bullet = '·';
  final String arrow = '→';
  final String section = '▼';
  final List<String> spinner = const [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];
}

const Symbols SYMBOLS = Symbols();

/// Mirror of the nested `color.action` object.
class ColorActionTheme {
  ColorActionTheme({Picocolors? pc}) : _pc = _resolvePicocolors(pc);

  final Picocolors _pc;

  String add(String s) => _pc.green(s);
  String modify(String s) => _pc.yellow(s);
  String delete(String s) => _pc.red(s);
}

/// Mirror of the TS `color` const object. The optional [Picocolors] override
/// is the DI seam replacing the vitest module mock of `picocolors`.
class ColorTheme {
  ColorTheme({Picocolors? pc})
    : _pc = _resolvePicocolors(pc),
      action = ColorActionTheme(pc: pc);

  final Picocolors _pc;
  final ColorActionTheme action;

  String success(String s) => _pc.green(s);
  String error(String s) => _pc.red(s);
  String warn(String s) => _pc.yellow(s);
  String info(String s) => _pc.cyan(s);
  String dim(String s) => _pc.dim(s);
  String bold(String s) => _pc.bold(s);
  String header(String s) => _pc.bold(s);
  String path(String s) => _pc.dim(s);
  String label(String s) => _pc.dim(s);
  String highlight(String s) => _pc.cyan(s);
}

final ColorTheme color = ColorTheme();
