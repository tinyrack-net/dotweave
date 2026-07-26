// Targeted tests pinning the stricli-parity surfaces replicated by
// lib/src/router.dart. Expected strings are derived from the actual
// stricli implementation in
// `packages/cli/node_modules/@stricli/core/dist/index.js` (help/usage
// rendering, scanner error templates, did-you-mean suggestions, exit codes,
// and completion proposals), so the later `commands.test.ts` port lands on a
// router with verified behavior.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

import 'helpers/capture_stream.dart';

FutureOr<List<String>> _proposeTargets(String partial) {
  return const ['alpha', 'beta'];
}

final List<(Map<String, Object?>, List<Object?>)> _calls = [];

Command _buildParseCommand() {
  return buildCommand(
    docs: const CommandDocs(brief: 'Parse test command'),
    func: (context, flags, positional) {
      _calls.add((flags, positional));
      return null;
    },
    parameters: const CommandParameters(
      flags: {
        'dryRun': BooleanFlag(brief: 'Preview only', optional: true),
        'kind': EnumFlag(
          brief: 'Target kind',
          optional: true,
          values: ['file', 'directory'],
        ),
        'mode': ParsedFlag(
          brief: 'Sync mode',
          optional: true,
          parse: stringParser,
          placeholder: 'mode',
          variadic: true,
        ),
        'profile': ParsedFlag(
          brief: 'Profile name',
          optional: true,
          parse: stringParser,
          placeholder: 'profile',
        ),
      },
      positional: TuplePositionalParameters([
        PositionalParameter(
          brief: 'Target path',
          parse: stringParser,
          placeholder: 'target',
          proposeCompletions: _proposeTargets,
        ),
        PositionalParameter(
          brief: 'Extra value',
          parse: stringParser,
          placeholder: 'extra',
          optional: true,
        ),
      ]),
    ),
  );
}

Command _buildReqCommand() {
  return buildCommand(
    docs: const CommandDocs(brief: 'Required-arguments test command'),
    func: (context, flags, positional) => null,
    parameters: const CommandParameters(
      flags: {
        'token': ParsedFlag(
          brief: 'Token value',
          parse: stringParser,
          placeholder: 'token',
        ),
      },
      positional: TuplePositionalParameters([
        PositionalParameter(
          brief: 'Target path',
          parse: stringParser,
          placeholder: 'target',
        ),
      ]),
    ),
  );
}

Command _buildManyCommand() {
  return buildCommand(
    docs: const CommandDocs(brief: 'Variadic-arguments test command'),
    func: (context, flags, positional) => null,
    parameters: const CommandParameters(
      positional: ArrayPositionalParameters(
        parameter: PositionalParameter(
          brief: 'Item value',
          parse: stringParser,
          placeholder: 'item',
        ),
        minimum: 1,
        maximum: 2,
      ),
    ),
  );
}

class _CodedError implements Exception {
  const _CodedError();
}

Command _buildBoomCommand() {
  return buildCommand(
    docs: const CommandDocs(brief: 'Failing test command'),
    func: (context, flags, positional) {
      throw Exception('kaput');
    },
    parameters: const CommandParameters(),
  );
}

Command _buildCodedCommand() {
  return buildCommand(
    docs: const CommandDocs(brief: 'Coded-exit test command'),
    func: (context, flags, positional) {
      throw const _CodedError();
    },
    parameters: const CommandParameters(),
  );
}

Application _buildTestApplication() {
  final root = buildRouteMap(
    docs: const RouteMapDocs(brief: 'Test CLI'),
    routes: {
      'parse': _buildParseCommand(),
      'req': _buildReqCommand(),
      'many': _buildManyCommand(),
      'boom': _buildBoomCommand(),
      'coded': _buildCodedCommand(),
    },
  );
  return buildApplication(
    root,
    ApplicationConfiguration(
      completion: const CompletionConfiguration(includeAliases: false),
      determineExitCode: (error) => error is _CodedError ? 7 : 1,
      documentation: const DocumentationConfiguration(
        caseStyle: DisplayCaseStyle.convertCamelToKebab,
      ),
      name: 'test',
      scanner: const ScannerConfiguration(
        caseStyle: ScannerCaseStyle.allowKebabForCamel,
      ),
      versionInfo: const VersionInformation(currentVersion: 'test/1.0.0'),
    ),
  );
}

Future<({int exitCode, String stdout, String stderr})> _runApp(
  Application app,
  List<String> inputs,
) async {
  final stdout = CaptureStream();
  final stderr = CaptureStream();
  final process = RunProcess(stdout: stdout, stderr: stderr);

  await run(app, inputs, RunContext(process: process));

  return (
    exitCode: process.exitCode ?? 0,
    stdout: stdout.text,
    stderr: stderr.text,
  );
}

Future<List<InputCompletion>> _propose(
  Application app,
  List<String> inputs,
) async {
  final process = RunProcess(stdout: CaptureStream(), stderr: CaptureStream());
  return proposeCompletions(app, inputs, RunContext(process: process));
}

void main() {
  setUp(_calls.clear);

  group('help rendering', () {
    test('prints the enum values column for enum flags', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--help']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('[--kind]'));
      expect(result.stdout, contains('[file|directory]'));
      expect(result.stdout, contains('[--mode]...'));
      expect(result.stdout, contains('[--mode mode]...'));
      expect(result.stdout, contains('<target> [<extra>]'));
    });
  });

  group('version flag', () {
    test('prints the configured version for --version and -v', () async {
      final app = _buildTestApplication();

      final long = await _runApp(app, ['--version']);
      expect(long.exitCode, 0);
      expect(long.stdout, 'test/1.0.0\n');
      expect(long.stderr, '');

      final short = await _runApp(app, ['-v']);
      expect(short.exitCode, 0);
      expect(short.stdout, 'test/1.0.0\n');
    });
  });

  group('argument scanning', () {
    test('accepts kebab-case input for camelCase flags', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--dry-run', 'x']);

      expect(result.exitCode, 0);
      expect(_calls, hasLength(1));
      expect(_calls[0].$1['dryRun'], true);
      expect(_calls[0].$2, ['x', null]);
    });

    test('accepts the original camelCase flag name', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--dryRun', 'x']);

      expect(result.exitCode, 0);
      expect(_calls[0].$1['dryRun'], true);
    });

    test('supports boolean negation via --no-dry-run', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--no-dry-run', 'x']);

      expect(result.exitCode, 0);
      expect(_calls[0].$1['dryRun'], false);
    });

    test('leaves omitted optional flags null', () async {
      final app = _buildTestApplication();
      await _runApp(app, ['parse', 'x']);

      expect(_calls[0].$1.containsKey('dryRun'), isTrue);
      expect(_calls[0].$1['dryRun'], isNull);
      expect(_calls[0].$1['profile'], isNull);
    });

    test('supports --flag=value syntax', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--profile=work', 'x']);

      expect(result.exitCode, 0);
      expect(_calls[0].$1['profile'], 'work');
    });

    test('collects variadic flag inputs in order', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, [
        'parse',
        '--mode',
        'a',
        '--mode',
        'b',
        'x',
      ]);

      expect(result.exitCode, 0);
      expect(_calls[0].$1['mode'], ['a', 'b']);
    });

    test('validates enum values', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--kind', 'file', 'x']);

      expect(result.exitCode, 0);
      expect(_calls[0].$1['kind'], 'file');
    });
  });

  group('scanner errors', () {
    test('reports invalid enum values with the stricli template', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--kind', 'bogus', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(result.stdout, '');
      expect(result.stderr, 'Expected "bogus" to be one of (file|directory)\n');
    });

    test('suggests close enum values', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--kind', 'fil', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Expected "fil" to be one of (file|directory), did you mean "file"?\n',
      );
    });

    test('reports unknown flags', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--bogus', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(result.stderr, 'No flag registered for --bogus\n');
    });

    test('suggests close flag names for unknown flags', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--profil', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'No flag registered for --profil, did you mean --profile?\n',
      );
    });

    test('reports unknown single-letter aliases', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '-x', 'y']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(result.stderr, 'No alias registered for -x\n');
    });

    test('reports a flag interrupted by another flag', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--mode', '--dry-run', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Expected input for flag --mode but encountered --dry-run instead\n',
      );
    });

    test('reports repeated non-variadic flags', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, [
        'parse',
        '--profile',
        'a',
        '--profile',
        'b',
        'x',
      ]);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Too many arguments for --profile, encountered "b" after "a"\n',
      );
    });

    test('reports unexpected positional arguments', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', 'a', 'b', 'c']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Too many arguments, expected 2 but encountered "c"\n',
      );
    });

    test('reports a missing required positional argument', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['many']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Expected at least 1 argument(s) for item but found none\n',
      );
    });

    test('reports missing positional and flag errors on separate lines in '
        'stricli order', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['req']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Expected argument for target\n'
        'Expected input for flag --token\n',
      );
    });

    test('rejects negated flags combined with =value', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse', '--no-dry-run=true', 'x']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(
        result.stderr,
        'Cannot negate flag --no-dry-run and pass "true" as value\n',
      );
    });
  });

  group('route resolution errors', () {
    test('reports unknown commands with backticked suggestions', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['pars']);

      expect(result.exitCode, ExitCode.unknownCommand);
      expect(result.stdout, '');
      expect(
        result.stderr,
        'No command registered for `pars`, did you mean `parse`?\n',
      );
    });

    test('reports unknown commands without suggestions', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['zzzzzzz']);

      expect(result.exitCode, ExitCode.unknownCommand);
      expect(result.stderr, 'No command registered for `zzzzzzz`\n');
    });
  });

  group('exit codes', () {
    test('uses -5 for unknown commands', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['nope']);

      expect(result.exitCode, ExitCode.unknownCommand);
    });

    test('uses -4 for invalid arguments', () async {
      final app = _buildTestApplication();
      final result = await _runApp(app, ['parse']);

      expect(result.exitCode, ExitCode.invalidArgument);
      expect(result.stderr, 'Expected argument for target\n');
    });

    test('routes thrown command errors through determineExitCode', () async {
      final app = _buildTestApplication();

      final generic = await _runApp(app, ['boom']);
      expect(generic.exitCode, 1);
      expect(generic.stderr, 'Command failed, Exception: kaput\n');

      final coded = await _runApp(app, ['coded']);
      expect(coded.exitCode, 7);
    });

    test('uses 0 for success and preserves pre-set exit codes', () async {
      final app = _buildTestApplication();

      final success = await _runApp(app, ['parse', 'x']);
      expect(success.exitCode, 0);

      final process = RunProcess(
        stdout: CaptureStream(),
        stderr: CaptureStream(),
      );
      process.exitCode = 3;
      await run(app, ['parse', 'x'], RunContext(process: process));
      expect(process.exitCode, 3);
    });
  });

  group('completion proposals', () {
    test('proposes route names for a partial command', () async {
      final app = _buildTestApplication();
      final completions = await _propose(app, ['pa']);

      expect(completions, hasLength(1));
      expect(completions[0].kind, 'routing-target:command');
      expect(completions[0].completion, 'parse');
      expect(completions[0].brief, 'Parse test command');
    });

    test('proposes kebab-case flag names after --', () async {
      final app = _buildTestApplication();
      final completions = await _propose(app, ['parse', '--']);

      expect(completions.map((c) => c.completion).toList(), [
        '--dry-run',
        '--kind',
        '--mode',
        '--profile',
      ]);
      expect(completions.every((c) => c.kind == 'argument:flag'), isTrue);
    });

    test('filters flag proposals by the partial input', () async {
      final app = _buildTestApplication();
      final completions = await _propose(app, ['parse', '--dr']);

      expect(completions.map((c) => c.completion).toList(), ['--dry-run']);
    });

    test('excludes satisfied non-variadic flags from proposals', () async {
      final app = _buildTestApplication();
      final completions = await _propose(app, ['parse', 'x', '--dry-run', '']);

      expect(completions.map((c) => c.completion).toList(), [
        '--kind',
        '--mode',
        '--profile',
      ]);
    });

    test('proposes enum values for the active flag', () async {
      final app = _buildTestApplication();

      final all = await _propose(app, ['parse', '--kind', '']);
      expect(all.map((c) => c.completion).toList(), ['file', 'directory']);
      expect(all.every((c) => c.kind == 'argument:value'), isTrue);
      expect(all[0].brief, 'Target kind');

      final filtered = await _propose(app, ['parse', '--kind', 'fi']);
      expect(filtered.map((c) => c.completion).toList(), ['file']);
    });

    test(
      'proposes positional completions from the parameter callback',
      () async {
        final app = _buildTestApplication();
        final completions = await _propose(app, ['parse', 'al']);

        expect(completions, hasLength(1));
        expect(completions[0].kind, 'argument:value');
        expect(completions[0].completion, 'alpha');
        expect(completions[0].brief, 'Target path');
      },
    );

    test('returns no completions for empty input or help requests', () async {
      final app = _buildTestApplication();

      expect(await _propose(app, []), isEmpty);
      expect(await _propose(app, ['parse', '--help', 'x']), isEmpty);
    });
  });
}
