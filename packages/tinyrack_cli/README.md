# tinyrack_cli

A typed CLI framework for Dart: command routing, argument scanning, rendered
help, structured exit codes, and shell-completion proposals — plus a terminal
logger, spinner, and colour theme.

> **Status: pre-release.** The API is not stable yet and the package is not
> published. It is developed inside the
> [dotweave](https://github.com/tinyrack/dotweave) repository, which is its
> first consumer.

## Why not `package:args`?

`package:args` is the right choice for most Dart CLIs. Reach for this one only
if you need what it does not provide:

- **Completion proposals in the core.** The framework computes the candidate
  list for any partial command line — including per-argument dynamic values
  (file paths, remote names) supplied by your own callback. `package:args` has
  no completion API; `cli_completion` adds one for bash and zsh only.
- **Full control of help layout.** Help is rendered by this package rather than
  a private class, so `USAGE` / `FLAGS` / `ARGUMENTS` / `COMMANDS` sections,
  column alignment, and the `--flag/--no-flag` presentation are all part of the
  contract you can pin in tests.
- **kebab⇄camelCase aliasing.** `--dry-run` and `--dryRun` both bind to a
  `dryRun` flag, without per-option alias lists.
- **Structured exit codes.** Distinct negative codes for unknown command,
  invalid argument, and command-load failure, plus a hook to derive an exit
  code from a thrown error.

## Libraries

```dart
import 'package:tinyrack_cli/tinyrack_cli.dart'; // commands, flags, help, completion
import 'package:tinyrack_cli/terminal.dart';     // logger, spinner, colour theme
```

They are separate so that a consumer who only needs argument parsing does not
pull in the terminal layer.

## Example

See [`example/main.dart`](example/main.dart) for a runnable two-command app.
The shape is:

```dart
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
```

```console
$ dart run example/main.dart greet --loud world
HELLO, WORLD!

$ dart run example/main.dart gret world
No command registered for `gret`, did you mean `greet`?

$ dart run example/main.dart --help
USAGE
  example greet [--loud] <name>
  example --help

Example CLI

FLAGS
  -h --help  Print help information and exit

COMMANDS
  greet  Greet someone
```

## Environment access

Anywhere this package consults the environment (`NO_COLOR`, `FORCE_COLOR`,
`CI`, `TERM`, `STRICLI_NO_COLOR`) it takes an `EnvLookup` — a
`String? Function(String name)` — defaulting to `lookupPlatformEnv`, which
reads `Platform.environment` with a case-insensitive fallback on Windows. Pass
your own to read from a validated wrapper, a config overlay, or a test double.

## Origin

This is a Dart implementation of the design introduced by Bloomberg's
TypeScript [`@stricli/core`](https://github.com/bloomberg/stricli): its command
model, help layout, scanner error messages, and completion approach were the
reference. It is an independent project, not a binding, and is not affiliated
with or endorsed by Bloomberg.
