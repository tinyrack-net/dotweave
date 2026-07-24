/// Error type used across the tools CLI for expected failures.
///
/// The application layer catches [ToolException] and prints [message]
/// without a stack trace.
class ToolException implements Exception {
  const ToolException(this.message);

  final String message;

  @override
  String toString() => message;
}
