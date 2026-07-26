import 'package:test/test.dart';
import 'package:tinyrack_cli/terminal.dart';

import 'mock_factories.dart';

/// Mirror of the vitest `./theme.ts` mock: each color tags its input with the
/// color-function name.
class _TagColorActionTheme implements ColorActionTheme {
  @override
  String add(String s) => 'add($s)';

  @override
  String modify(String s) => 'modify($s)';

  @override
  String delete(String s) => 'delete($s)';
}

class _TagColorTheme implements ColorTheme {
  String _tag(String name, String input) => '$name($input)';

  @override
  final ColorActionTheme action = _TagColorActionTheme();

  @override
  String success(String s) => _tag('success', s);

  @override
  String error(String s) => _tag('error', s);

  @override
  String warn(String s) => _tag('warn', s);

  @override
  String info(String s) => _tag('info', s);

  @override
  String dim(String s) => _tag('dim', s);

  @override
  String bold(String s) => _tag('bold', s);

  @override
  String header(String s) => _tag('header', s);

  @override
  String path(String s) => _tag('path', s);

  @override
  String label(String s) => _tag('label', s);

  @override
  String highlight(String s) => _tag('highlight', s);
}

/// Manual replacement for `vi.useFakeTimers`: ticks fire only when the test
/// advances them.
class _ManualSpinnerTimer implements SpinnerTimer {
  _ManualSpinnerTimer(this._onTick);

  final void Function() _onTick;
  bool cancelled = false;

  @override
  void cancel() {
    cancelled = true;
  }

  /// Simulates `vi.advanceTimersByTime(ticks * 80)`.
  void advance(int ticks) {
    for (var i = 0; i < ticks; i++) {
      if (cancelled) {
        return;
      }
      _onTick();
    }
  }
}

void main() {
  group('spinner', () {
    group('non-TTY path', () {
      test('writes a static bullet line on creation when isTTY is false', () {
        final stream = createMockStream(false);

        createSpinner(stream, 'loading...', color: _TagColorTheme());
        expect(stream.writes, hasLength(1));
        expect(stream.writes[0], contains('loading...'));
      });

      test('succeed writes a final success line', () {
        final stream = createMockStream(false);

        final spinner = createSpinner(
          stream,
          'loading...',
          color: _TagColorTheme(),
        );
        stream.writes.clear();

        spinner.succeed('done');
        expect(stream.writes, hasLength(1));
        expect(stream.writes[0], contains('done'));
        expect(stream.writes[0], contains('success('));
      });

      test('fail writes a final error line', () {
        final stream = createMockStream(false);

        final spinner = createSpinner(
          stream,
          'loading...',
          color: _TagColorTheme(),
        );
        stream.writes.clear();

        spinner.fail('error');
        expect(stream.writes, hasLength(1));
        expect(stream.writes[0], contains('error'));
        expect(stream.writes[0], contains('error('));
      });

      test('warn writes a final warn line', () {
        final stream = createMockStream(false);

        final spinner = createSpinner(
          stream,
          'loading...',
          color: _TagColorTheme(),
        );
        stream.writes.clear();

        spinner.warn('caution');
        expect(stream.writes, hasLength(1));
        expect(stream.writes[0], contains('caution'));
        expect(stream.writes[0], contains('warn('));
      });

      test('stop does nothing visible on non-TTY', () {
        final stream = createMockStream(false);

        final spinner = createSpinner(
          stream,
          'loading...',
          color: _TagColorTheme(),
        );
        stream.writes.clear();

        spinner.stop();
        expect(stream.writes, hasLength(0));
      });
    });

    group('TTY path', () {
      // Mirrors the vitest beforeEach stubbing CI/NO_COLOR/FORCE_COLOR to ''.
      const stubbedEnvValues = {'CI': '', 'NO_COLOR': '', 'FORCE_COLOR': ''};
      String? stubbedEnv(String name) => stubbedEnvValues[name];

      ({Spinner spinner, _ManualSpinnerTimer timer}) createTtySpinner(
        MockStream stream,
        String text,
      ) {
        _ManualSpinnerTimer? timer;
        final spinner = createSpinner(
          stream,
          text,
          color: _TagColorTheme(),
          readEnv: stubbedEnv,
          startInterval: (Duration interval, void Function() onTick) {
            timer = _ManualSpinnerTimer(onTick);
            return timer!;
          },
        );
        return (spinner: spinner, timer: timer!);
      }

      test('starts an interval and renders the first frame', () {
        final stream = createMockStream(true);

        createTtySpinner(stream, 'working');

        expect(stream.writes.length, greaterThanOrEqualTo(1));
      });

      test('succeed clears interval and writes final line', () {
        final stream = createMockStream(true);

        final handle = createTtySpinner(stream, 'working');
        handle.timer.advance(2);
        stream.writes.clear();

        handle.spinner.succeed('complete');

        expect(stream.writes.any((w) => w.contains('complete')), isTrue);
      });

      test('fail clears interval and writes final line', () {
        final stream = createMockStream(true);

        final handle = createTtySpinner(stream, 'working');
        handle.timer.advance(2);
        stream.writes.clear();

        handle.spinner.fail('broken');

        expect(stream.writes.any((w) => w.contains('broken')), isTrue);
      });

      test('stop clears interval and clears the line', () {
        final stream = createMockStream(true);

        final handle = createTtySpinner(stream, 'working');
        handle.timer.advance(2);

        handle.spinner.stop();

        expect(stream.clearLineCalls, greaterThan(0));
        expect(handle.timer.cancelled, isTrue);
      });

      test('warn clears interval and writes final line', () {
        final stream = createMockStream(true);

        final handle = createTtySpinner(stream, 'working');
        handle.timer.advance(2);
        stream.writes.clear();

        handle.spinner.warn('caution');

        expect(stream.writes.any((w) => w.contains('caution')), isTrue);
      });

      test('does not render after stop is called', () {
        final stream = createMockStream(true);

        final handle = createTtySpinner(stream, 'working');
        handle.timer.advance(2);
        handle.spinner.stop();
        stream.writes.clear();

        handle.timer.advance(2);

        expect(stream.writes, hasLength(0));
      });
    });
  });
}
