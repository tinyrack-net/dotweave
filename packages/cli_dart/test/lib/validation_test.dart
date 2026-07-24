import 'package:dotweave/src/lib/validation.dart';
import 'package:test/test.dart';

void main() {
  group('validation helpers', () {
    test('formats root-level issues as input', () {
      const issues = [ValidationIssue(path: [], message: 'Invalid request.')];

      expect(formatInputIssues(issues), '- input: Invalid request.');
    });

    test('formats nested issue paths with dot notation', () {
      const issues = [
        ValidationIssue(
          path: ['entries', 0, 'repoPath'],
          message: 'Value must not be empty.',
        ),
      ];

      expect(
        formatInputIssues(issues),
        '- entries.0.repoPath: Value must not be empty.',
      );
    });

    test('formats multiple issues on separate lines', () {
      const issues = [
        ValidationIssue(path: ['name'], message: 'Required.'),
        ValidationIssue(path: ['email'], message: 'Invalid format.'),
      ];

      expect(
        formatInputIssues(issues),
        '- name: Required.\n- email: Invalid format.',
      );
    });

    test('formats deeply nested paths with 3+ levels', () {
      const issues = [
        ValidationIssue(
          path: ['config', 'entries', 0, 'mode', 'default'],
          message: 'Bad mode.',
        ),
      ];

      expect(
        formatInputIssues(issues),
        '- config.entries.0.mode.default: Bad mode.',
      );
    });

    test('handles numeric path segments correctly', () {
      const issues = [
        ValidationIssue(path: ['items', 2, 'name'], message: 'Missing.'),
      ];

      expect(formatInputIssues(issues), '- items.2.name: Missing.');
    });

    test('handles special characters in path segments', () {
      const issues = [
        ValidationIssue(path: ['field-with-dashes'], message: 'Invalid.'),
      ];

      expect(formatInputIssues(issues), '- field-with-dashes: Invalid.');
    });

    test('formats an empty issues list as empty string', () {
      expect(formatInputIssues(const []), '');
    });
  });
}
