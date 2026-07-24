// Dart port of `packages/cli/src/application.ts`.
//
// The TS module wires the stricli application once at import time against the
// global `process` streams; the Dart port builds it per `runCli` invocation so
// tests can inject capture streams (the seam replacing the TS tests' spies on
// `process.stdout.write` / `process.stderr.write`).

import 'dart:convert';
import 'dart:io' as io;

import 'package:dotweave/src/cli/autocomplete.dart';
import 'package:dotweave/src/cli/index.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/version.dart';
import 'package:dotweave/src/services/terminal/logger.dart';

/// Mirror of the TS `CommandError` shape (`Error & { exitCode?: number }`).
/// Errors that should drive a custom process exit code implement this.
abstract interface class CommandExitCode {
  int? get exitCode;
}

/// Mirror of `stringifyThrownValue`.
String _stringifyThrownValue(Object? error) {
  if (error is String) {
    return error;
  }

  try {
    final serialized = jsonEncode(error);

    return serialized;
  } catch (_) {
    // Fall back to toString() for circular or otherwise non-serializable
    // values (the TS module falls back to String()).
  }

  return '$error';
}

String formatApplicationError(Object? error) {
  return formatDotweaveError(
    error is Error || error is Exception
        ? error as Object
        : _stringifyThrownValue(error),
  );
}

/// Mirror of `resolveExitCode`: reads `error.exitCode ?? 1` when the thrown
/// value carries a numeric exit code, else 1.
int resolveExitCode(Object? error) {
  if (error is CommandExitCode) {
    return error.exitCode ?? 1;
  }

  return 1;
}

/// Mirror of the TS `dotweaveText` overrides on top of `text_en`; the logger
/// is injected so error output follows the active stderr stream.
ApplicationText _buildDotweaveText(CliLogger errorLogger) {
  String formatErrorForConsola(Object? error) {
    final message = formatApplicationError(error);
    errorLogger.error(message);
    return '';
  }

  return textEn.copyWith(
    commandErrorResult: (error, ansiColor) {
      return formatErrorForConsola(error);
    },
    exceptionWhileLoadingCommandContext: (error, ansiColor) {
      return formatErrorForConsola(error);
    },
    exceptionWhileLoadingCommandFunction: (error, ansiColor) {
      return formatErrorForConsola(error);
    },
    exceptionWhileRunningCommand: (error, ansiColor) {
      return formatErrorForConsola(error);
    },
    noCommandRegisteredForInput: (args) {
      final suggestion = args.corrections.isEmpty
          ? ''
          : ' Did you mean ${args.corrections.map((entry) => '"$entry"').join(', ')}?';

      errorLogger.error('Command "${args.input}" not found.$suggestion');
      return '';
    },
  );
}

Application _buildApplication(ApplicationText dotweaveText) {
  return buildApplication(
    buildRootRoute(),
    ApplicationConfiguration(
      completion: const CompletionConfiguration(includeAliases: false),
      determineExitCode: resolveExitCode,
      documentation: const DocumentationConfiguration(
        caseStyle: DisplayCaseStyle.convertCamelToKebab,
      ),
      localization: LocalizationConfiguration(
        defaultLocale: 'en',
        loadText: (locale) => dotweaveText,
      ),
      name: AppConstants.app.name,
      scanner: const ScannerConfiguration(
        caseStyle: ScannerCaseStyle.allowKebabForCamel,
      ),
      versionInfo: VersionInformation(currentVersion: currentVersion),
    ),
  );
}

/// Adapts a `dart:io` [io.Stdout] to the logger/router stream surface.
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

/// Runs the dotweave CLI and returns the process exit code (the TS module
/// assigns it to `process.exitCode`; `bin/dotweave.dart` applies the returned
/// value and flushes stdout/stderr).
Future<int> runCli(
  List<String> inputs, {
  Stream? stdout,
  Stream? stderr,
}) async {
  final stdoutStream = stdout ?? _StdioStream(io.stdout);
  final stderrStream = stderr ?? _StdioStream(io.stderr);
  final errorLogger = createCliLogger(
    stderr: stderrStream,
    stdout: stderrStream,
  );
  final application = _buildApplication(_buildDotweaveText(errorLogger));

  setApplication(application);

  final process = RunProcess(stdout: stdoutStream, stderr: stderrStream);

  await run(application, inputs, RunContext(process: process));

  return process.exitCode ?? 0;
}
