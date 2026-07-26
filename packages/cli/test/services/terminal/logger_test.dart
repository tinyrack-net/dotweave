import 'package:dotweave/src/services/terminal/logger.dart';
import 'package:dotweave/src/services/terminal/spinner.dart';
import 'package:dotweave/src/services/terminal/theme.dart';
import 'package:test/test.dart';

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

/// Mirror of the vitest `./spinner.ts` mock: a no-op spinner factory.
class _NoopSpinner implements Spinner {
  @override
  void succeed(String text) {}

  @override
  void fail(String text) {}

  @override
  void warn(String text) {}

  @override
  void stop() {}
}

CliLogger _createLogger({MockStream? stdout, MockStream? stderr, String? tag}) {
  return createCliLogger(
    stdout: stdout,
    stderr: stderr,
    tag: tag,
    color: _TagColorTheme(),
    createSpinner: (WriteStream stream, String text) => _NoopSpinner(),
  );
}

void main() {
  group('cli logger', () {
    group('without tag', () {
      test('writes log messages to stdout', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.log('hello');
        expect(stdout.writes, contains('hello\n'));
      });

      test('writes info messages with info symbol to stdout', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.info('information');
        expect(stdout.writes[0], contains('information'));
        expect(stdout.writes[0], contains('info('));
      });

      test('writes success messages with success symbol to stdout', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.success('done');
        expect(stdout.writes[0], contains('done'));
        expect(stdout.writes[0], contains('success('));
      });

      test('writes fail messages with error symbol to stdout', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.fail('broken');
        expect(stdout.writes[0], contains('broken'));
        expect(stdout.writes[0], contains('error('));
      });

      test('writes start messages with bullet and dim to stdout', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.start('loading...');
        expect(stdout.writes[0], contains('loading...'));
      });

      test('writes warn messages to stderr', () {
        final stderr = createMockStream();
        final logger = _createLogger(stderr: stderr);

        logger.warn('caution');
        expect(stderr.writes[0], contains('caution'));
        expect(stderr.writes[0], contains('warn('));
      });

      test('writes error messages to stderr', () {
        final stderr = createMockStream();
        final logger = _createLogger(stderr: stderr);

        logger.error('critical');
        expect(stderr.writes[0], contains('critical'));
        expect(stderr.writes[0], contains('error('));
      });
    });

    group('with tag', () {
      test('prepends [tag] to all output lines', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout, tag: 'sync');

        logger.log('message');
        expect(stdout.writes[0], contains('[sync]'));
        expect(stdout.writes[0], contains('message'));
      });
    });

    group('section', () {
      test('writes a blank line then a bold title', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.section('Details');
        expect(stdout.writes[0], '\n');
        expect(stdout.writes[1], contains('Details'));
        expect(stdout.writes[1], contains('bold('));
      });
    });

    group('kv', () {
      test('renders indented label: value', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.kv('key', 'value');
        expect(stdout.writes[0], contains('key'));
        expect(stdout.writes[0], contains('value'));
        expect(stdout.writes[0], contains('label('));
      });
    });

    group('list', () {
      test('renders items with default bullet', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.list(['alpha', 'beta']);
        expect(stdout.writes, hasLength(2));
        expect(stdout.writes[0], contains('- alpha'));
        expect(stdout.writes[1], contains('- beta'));
      });

      test('renders items with custom bullet', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.list(['alpha'], bullet: '*');
        expect(stdout.writes[0], contains('* alpha'));
      });

      test('highlights last item when highlightLast is true', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.list(['alpha', 'beta'], highlightLast: true);
        expect(stdout.writes[1], contains('highlight('));
      });

      test('renders nothing for an empty list', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.list([]);
        expect(stdout.writes, hasLength(0));
      });
    });

    group('listKeyValue', () {
      test('renders aligned key/value pairs', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.listKeyValue([
          (key: 'Name', value: 'dotweave'),
          (key: 'Version', value: '1.0'),
        ]);
        expect(stdout.writes, hasLength(2));
        expect(stdout.writes[0], contains('Name'));
        expect(stdout.writes[0], contains('dotweave'));
        expect(stdout.writes[1], contains('Version'));
        expect(stdout.writes[1], contains('1.0'));
      });

      test('renders key-only lines when value is undefined', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.listKeyValue([(key: 'Section', value: null)]);
        expect(stdout.writes, hasLength(1));
        expect(stdout.writes[0], contains('Section'));
      });
    });

    group('divider', () {
      test('writes a dim separator line', () {
        final stdout = createMockStream();
        final logger = _createLogger(stdout: stdout);

        logger.divider();
        expect(stdout.writes[0], contains('dim('));
      });
    });

    group('spinner', () {
      test('delegates to createSpinner with stdout', () {
        final stdout = createMockStream();
        WriteStream? receivedStream;
        final logger = createCliLogger(
          stdout: stdout,
          color: _TagColorTheme(),
          createSpinner: (WriteStream stream, String text) {
            receivedStream = stream;
            return _NoopSpinner();
          },
        );

        final spinner = logger.spinner('working...');
        expect(spinner, isA<Spinner>());
        expect(receivedStream, same(stdout));
      });
    });
  });
}
