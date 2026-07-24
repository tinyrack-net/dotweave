// Dart port of `packages/cli/src/test/helpers/pty.ts` plus
// `packages/cli/src/test/helpers/shell-availability.ts`.
//
// The TS helper drives interactive shells through node-pty. Dart has no pty
// binding, so this port wraps the POSIX `script` utility, which allocates a
// pty for the spawned command and mirrors the pty output on its own stdout:
//
// - Linux (util-linux): `script -qefc "<command>" /dev/null`
// - macOS (BSD):        `script -q /dev/null <command> <args...>`
//
// Input written to the session goes to `script`'s stdin, which forwards it to
// the pty master (so the shell under test sees a real tty). node-pty pinned
// the terminal to 120x40; `script` gets no window size from a piped stdin, so
// COLUMNS/LINES are exported as a hint instead.
//
// Windows has no `script` utility; [startPtySession] throws there. The pty
// e2e suites guard every test body with `if (Platform.isWindows) return;`
// (the TS suites' `process.platform !== "win32"` skip), so on Windows they
// compile but never spawn a session.
//
// The macOS node-pty `spawn-helper` chmod workaround from `pty.ts` has no
// Dart equivalent and is intentionally dropped.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// --- Port of `shell-availability.ts` ---------------------------------------

String? _probeShellPath(String shell) {
  final lookupCommand = Platform.isWindows ? 'where' : 'which';
  final isUnsupportedWindowsShell = Platform.isWindows && shell == 'bash';
  final ProcessResult result;

  try {
    result = Process.runSync(
      lookupCommand,
      [shell],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException {
    return null;
  }

  // `execFileSync` throws on a non-zero exit code; the TS catch returns
  // undefined.
  if (result.exitCode != 0) {
    return null;
  }

  final unsupportedWindowsBashPattern = RegExp(
    r'\\(?:Windows\\System32|Microsoft\\WindowsApps)\\bash\.exe$',
    caseSensitive: false,
  );

  for (final rawLine in (result.stdout as String).split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();

    if (line.isEmpty) {
      continue;
    }

    if (isUnsupportedWindowsShell &&
        unsupportedWindowsBashPattern.hasMatch(line)) {
      continue;
    }

    return line;
  }

  return null;
}

final String? bashPath = _probeShellPath('bash');
final String? fishPath = _probeShellPath('fish');
final String? powerShellPath =
    _probeShellPath('pwsh') ?? _probeShellPath('powershell');
final String? zshPath = _probeShellPath('zsh');

final bool isBashAvailable = bashPath != null;
final bool isFishAvailable = fishPath != null;
final bool isPowerShellAvailable = powerShellPath != null;
final bool isZshAvailable = zshPath != null;

// --- Port of `pty.ts` -------------------------------------------------------

/// Mirror of the TS `applyBackspaces`.
String applyBackspaces(String value) {
  final result = <String>[];

  for (final rune in value.runes) {
    if (rune == 0x08) {
      if (result.isNotEmpty) {
        result.removeLast();
      }
      continue;
    }

    result.add(String.fromCharCode(rune));
  }

  return result.join();
}

/// Mirror of Node's `util.stripVTControlCharacters` (the ansi-regex pattern).
final String _escapeCharacter = String.fromCharCode(0x1B);
final String _csiCharacter = String.fromCharCode(0x9B);
final String _bellCharacter = String.fromCharCode(0x07);
final String _stringTerminatorCharacter = String.fromCharCode(0x9C);

final RegExp _vtControlPattern = RegExp(
  '[$_escapeCharacter$_csiCharacter]'
  r'[\[\]()#;?]*'
  r'(?:(?:(?:(?:;[-a-zA-Z\d/#&.:=?%@~_]+)*'
  r'|[a-zA-Z\d]+(?:;[-a-zA-Z\d/#&.:=?%@~_]*)*)?'
  '(?:$_bellCharacter|$_escapeCharacter'
  r'\\'
  '|$_stringTerminatorCharacter))'
  r'|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))',
);

/// Mirror of Node's `stripVTControlCharacters` used by the TS helper.
String stripVtControlCharacters(String value) {
  return value.replaceAll(_vtControlPattern, '');
}

/// Mirror of the TS `normalizeTerminalOutput`.
String normalizeTerminalOutput(String value) {
  return applyBackspaces(
    stripVtControlCharacters(value),
  ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

String _posixShellQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

/// Mirror of the TS `PtySession` interface (`waitFor` and `waitForOutput`
/// take a [Duration] instead of milliseconds).
class PtySession {
  PtySession._(this._process) {
    const decoder = Utf8Decoder(allowMalformed: true);

    _process.stdout.transform(decoder).listen(_append);
    _process.stderr.transform(decoder).listen(_append);
    // The process may exit without reading stdin; swallow the broken-pipe
    // error instead of surfacing an unhandled async exception.
    unawaited(_process.stdin.done.then((_) {}, onError: (Object _) {}));
    unawaited(
      _process.exitCode.then((code) {
        _exitCode = code;
      }),
    );
  }

  final Process _process;
  final StreamController<void> _onOutput = StreamController<void>.broadcast();
  String _raw = '';
  int? _exitCode;

  void _append(String chunk) {
    _raw += chunk;
    _onOutput.add(null);
  }

  /// Mirror of `clearOutput`.
  void clearOutput() {
    _raw = '';
  }

  /// Mirror of `close` (node-pty `terminal.kill()`): kills the `script`
  /// wrapper, which closes the pty master and hangs up the shell inside it.
  void close() {
    unawaited(_process.stdin.close().then((_) {}, onError: (Object _) {}));
    _process.kill();
  }

  /// Mirror of `getOutput` (normalized terminal output).
  String getOutput() {
    return normalizeTerminalOutput(_raw);
  }

  /// Mirror of `waitForOutput`.
  Future<String> waitForOutput(
    bool Function(String output) predicate, [
    Duration timeout = const Duration(seconds: 10),
  ]) {
    final current = getOutput();

    if (predicate(current)) {
      return Future.value(current);
    }

    final completer = Completer<String>();
    late final StreamSubscription<void> subscription;
    final timer = Timer(timeout, () {
      unawaited(subscription.cancel());
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Timed out waiting for terminal output predicate.'
            '\n\n${getOutput()}',
          ),
        );
      }
    });

    subscription = _onOutput.stream.listen((_) {
      final next = getOutput();

      if (!predicate(next)) {
        return;
      }

      timer.cancel();
      unawaited(subscription.cancel());
      if (!completer.isCompleted) {
        completer.complete(next);
      }
    });

    return completer.future;
  }

  /// Mirror of `waitFor` (accepts a plain [String] or a [RegExp]).
  Future<String> waitFor(
    Pattern pattern, [
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    try {
      return await waitForOutput((output) => output.contains(pattern), timeout);
    } on StateError {
      throw StateError(
        'Timed out waiting for terminal output matching $pattern.'
        '\n\n${getOutput()}',
      );
    }
  }

  /// Mirror of `waitForExit`.
  Future<void> waitForExit([
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (_exitCode != null) {
      return;
    }

    try {
      await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      throw StateError('Timed out waiting for terminal exit.');
    }
  }

  /// Mirror of `write` (sent to the pty through `script`'s stdin).
  void write(String value) {
    try {
      _process.stdin.add(utf8.encode(value));
    } on StateError {
      // Writing after the wrapper exited is a no-op, like node-pty.
    }
  }
}

/// Mirror of the TS `createPtySession` (async because Dart process spawning
/// is): starts [file] with [args] inside a pty via the platform's `script`
/// utility. [env] entries are layered over the parent environment; `null`
/// values drop the variable (the TS `undefined` cleanup).
Future<PtySession> startPtySession({
  List<String> args = const [],
  required String cwd,
  Map<String, String?> env = const {},
  required String file,
}) async {
  final String executable;
  final List<String> scriptArgs;

  if (Platform.isLinux) {
    // util-linux: -q quiet, -e return child exit code, -f flush, -c command.
    executable = 'script';
    scriptArgs = [
      '-qefc',
      [file, ...args].map(_posixShellQuote).join(' '),
      '/dev/null',
    ];
  } else if (Platform.isMacOS) {
    // BSD script: the command and its arguments are positional.
    executable = 'script';
    scriptArgs = ['-q', '/dev/null', file, ...args];
  } else {
    throw UnsupportedError(
      'PTY sessions require the POSIX `script` utility; '
      'unsupported on ${Platform.operatingSystem}.',
    );
  }

  final merged = <String, String?>{...Platform.environment, ...env};
  final environment = <String, String>{};

  for (final entry in merged.entries) {
    final value = entry.value;

    if (value != null) {
      environment[entry.key] = value;
    }
  }

  environment['TERM'] = 'xterm-256color';
  // node-pty spawned with cols: 120, rows: 40; `script` cannot inherit a
  // window size from a piped stdin, so hint the geometry through the
  // environment instead.
  environment['COLUMNS'] = '120';
  environment['LINES'] = '40';

  final process = await Process.start(
    executable,
    scriptArgs,
    // On macOS the temporary directory /var is a symlink to /private/var;
    // resolve it like the TS helper does for node-pty.
    workingDirectory: await Directory(cwd).resolveSymbolicLinks(),
    environment: environment,
    includeParentEnvironment: false,
  );

  return PtySession._(process);
}
