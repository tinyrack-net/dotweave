/// Removes empty lines before error details are rendered or stored.
List<String> compactLines(Iterable<String?> lines) {
  return [
    for (final line in lines)
      if (line != null && line.trim().isNotEmpty) line,
  ];
}

class DotweaveError implements Exception {
  DotweaveError(
    this.message, {
    this.code,
    List<String> details = const [],
    this.hint,
  }) : details = List.unmodifiable(details);

  final String message;
  final String? code;
  final List<String> details;
  final String? hint;

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
