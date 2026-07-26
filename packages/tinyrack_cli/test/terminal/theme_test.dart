import 'package:test/test.dart';
import 'package:tinyrack_cli/terminal.dart';

/// Mirror of the vitest picocolors mock: each style tags its input with the
/// style name.
class _TagPicocolors implements Picocolors {
  String _tag(String name, String input) => '$name($input)';

  @override
  bool get isColorSupported => true;

  @override
  String bold(String input) => _tag('bold', input);

  @override
  String cyan(String input) => _tag('cyan', input);

  @override
  String dim(String input) => _tag('dim', input);

  @override
  String green(String input) => _tag('green', input);

  @override
  String red(String input) => _tag('red', input);

  @override
  String yellow(String input) => _tag('yellow', input);
}

void main() {
  group('theme', () {
    group('SYMBOLS constants', () {
      test('has expected symbol values', () {
        expect(SYMBOLS.success, '✔');
        expect(SYMBOLS.error, '✖');
        expect(SYMBOLS.warn, '⚠');
        expect(SYMBOLS.info, '~');
        expect(SYMBOLS.bullet, '·');
        expect(SYMBOLS.arrow, '→');
        expect(SYMBOLS.section, '▼');
      });

      test('has spinner frames array', () {
        expect(SYMBOLS.spinner, isA<List<String>>());
        expect(SYMBOLS.spinner.length, greaterThan(0));
      });
    });

    group('color functions', () {
      final color = ColorTheme(pc: _TagPicocolors());

      test('delegates success to green', () {
        expect(color.success('ok'), 'green(ok)');
      });

      test('delegates error to red', () {
        expect(color.error('fail'), 'red(fail)');
      });

      test('delegates warn to yellow', () {
        expect(color.warn('caution'), 'yellow(caution)');
      });

      test('delegates info to cyan', () {
        expect(color.info('note'), 'cyan(note)');
      });

      test('delegates dim to dim', () {
        expect(color.dim('faded'), 'dim(faded)');
      });

      test('delegates bold to bold', () {
        expect(color.bold('title'), 'bold(title)');
      });

      test('delegates header to bold', () {
        expect(color.header('heading'), 'bold(heading)');
      });

      test('delegates path to dim', () {
        expect(color.path('/some/path'), 'dim(/some/path)');
      });

      test('delegates label to dim', () {
        expect(color.label('key'), 'dim(key)');
      });

      test('delegates highlight to cyan', () {
        expect(color.highlight('item'), 'cyan(item)');
      });

      test('delegates action.add to green', () {
        expect(color.action.add('+'), 'green(+)');
      });

      test('delegates action.modify to yellow', () {
        expect(color.action.modify('~'), 'yellow(~)');
      });

      test('delegates action.delete to red', () {
        expect(color.action.delete('-'), 'red(-)');
      });
    });
  });
}
