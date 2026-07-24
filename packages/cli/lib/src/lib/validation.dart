/// A single validation problem, mirroring the shape of a Zod issue
/// (`path` segments are strings or ints, joined with `.` when rendered).
class ValidationIssue {
  const ValidationIssue({required this.path, required this.message});

  final List<Object> path;
  final String message;
}

/// Formats validation issues into CLI-friendly input error messages.
String formatInputIssues(List<ValidationIssue> issues) {
  return issues
      .map((issue) {
        final path = issue.path.isEmpty ? 'input' : issue.path.join('.');

        return '- $path: ${issue.message}';
      })
      .join('\n');
}
