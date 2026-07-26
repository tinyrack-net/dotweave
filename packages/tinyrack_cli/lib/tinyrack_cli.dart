/// A typed CLI framework: command routing, argument scanning, rendered help,
/// structured exit codes, and shell-completion proposals.
///
/// Build commands with [buildCommand], group them with [buildRouteMap],
/// assemble an [Application] with [buildApplication], and dispatch with [run].
///
/// The terminal logger, spinner, and colour theme live in a separate library
/// (`package:tinyrack_cli/terminal.dart`) so that consumers who only need
/// argument parsing do not pull them in.
///
/// This is a Dart implementation of the model introduced by Bloomberg's
/// TypeScript [`@stricli/core`](https://github.com/bloomberg/stricli). It is
/// an independent project and is not affiliated with or endorsed by Bloomberg.
library;

export 'src/completion_scripts.dart';
export 'src/env.dart' show EnvLookup, lookupPlatformEnv;
export 'src/router.dart';
export 'src/write_stream.dart';
