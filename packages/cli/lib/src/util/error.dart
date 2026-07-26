import 'dart:io';

/// Mirror of the TS `CommandError` shape (`Error & { exitCode?: number }`).
/// Errors that should drive a custom process exit code implement this.
abstract interface class CommandExitCode {
  int? get exitCode;
}

/// Removes empty lines before error details are rendered or stored.
List<String> compactLines(Iterable<String?> lines) {
  return [
    for (final line in lines)
      if (line != null && line.trim().isNotEmpty) line,
  ];
}

/// Whether errors should carry (and render) the stack trace of their throw
/// site. Off by default so normal CLI output is unchanged.
///
/// The router catches command failures with a bare `catch (exc)` and its text
/// callbacks take no `StackTrace`, so there is no seam to thread a trace
/// through without editing the vendored stricli port. Capturing at
/// construction sidesteps that entirely, and points at the throw site rather
/// than the catch site, which is the more useful of the two anyway.
final bool errorDebugEnabled = Platform.environment['DOTWEAVE_DEBUG'] == '1';

class DotweaveError implements Exception {
  DotweaveError(
    this.message, {
    this.code,
    List<String> details = const [],
    this.hint,
  }) : details = List.unmodifiable(details),
       debugStackTrace = errorDebugEnabled ? StackTrace.current : null;

  final String message;
  final String? code;
  final List<String> details;
  final String? hint;

  /// Stack trace of the throw site, captured only under `DOTWEAVE_DEBUG=1`.
  final StackTrace? debugStackTrace;

  @override
  String toString() => message;
}

/// Extracts a human-readable message from an arbitrary thrown value,
/// mirroring how TS reads `error.message` from `Error` instances.
String extractErrorMessage(Object error) {
  if (error is String) {
    return error;
  }
  if (error is DotweaveError) {
    return error.message;
  }
  final text = error.toString();
  const prefixes = ['Exception: ', 'Bad state: '];
  for (final prefix in prefixes) {
    if (text.startsWith(prefix)) {
      return text.substring(prefix.length);
    }
  }
  return text;
}

/// Renders supported error values into the user-facing dotweave error format.
String formatDotweaveError(Object error) {
  if (error is String) {
    return error;
  }

  if (error is! DotweaveError) {
    return extractErrorMessage(error);
  }

  return compactLines([
    error.message,
    ...error.details,
    if (error.hint != null) '→ ${error.hint}',
    if (error.debugStackTrace != null) '\n${error.debugStackTrace}',
  ]).join('\n');
}

/// Wraps unknown failures in a DotweaveError with normalized detail lines.
DotweaveError wrapUnknownError(
  String message,
  Object error, {
  String? code,
  List<String> details = const [],
  String? hint,
}) {
  final detail = error is DotweaveError
      ? formatDotweaveError(error)
      : extractErrorMessage(error).trim();

  return DotweaveError(
    message,
    code: code,
    details: compactLines([...details, detail]),
    hint: hint,
  );
}
