// A minimal two-command application.
//
// Run it with:
//   dart run example/main.dart greet world
//   dart run example/main.dart greet --loud world
//   dart run example/main.dart --help

import 'dart:io';

import 'package:tinyrack_cli/tinyrack_cli.dart';

final greetCommand = buildCommand(
  docs: const CommandDocs(brief: 'Greet someone'),
  parameters: const CommandParameters(
    flags: {'loud': BooleanFlag(brief: 'Shout the greeting', optional: true)},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Who to greet',
        parse: stringParser,
        placeholder: 'name',
      ),
    ]),
  ),
  func: (context, flags, positional) {
    final greeting = 'Hello, ${positional[0]}!';

    context.process.stdout.write(
      '${flags['loud'] == true ? greeting.toUpperCase() : greeting}\n',
    );

    return null;
  },
);

Future<void> main(List<String> args) async {
  final app = buildApplication(
    buildRouteMap(
      docs: const RouteMapDocs(brief: 'Example CLI'),
      routes: {'greet': greetCommand},
    ),
    ApplicationConfiguration(
      name: 'example',
      // Lets `--dry-run` bind to a `dryRun` flag, and vice versa.
      scanner: const ScannerConfiguration(
        caseStyle: ScannerCaseStyle.allowKebabForCamel,
      ),
    ),
  );

  final process = RunProcess(
    stdout: StdioWriteStream(stdout),
    stderr: StdioWriteStream(stderr),
  );

  await run(app, args, RunContext(process: process));

  exitCode = process.exitCode ?? 0;
}
