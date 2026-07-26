import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/terminal/logger.dart';

/// Builds a logger bound to the streams of the command's own [context].
///
/// Every command used to call `createCliLogger()` with no arguments, which
/// resolves to the process-wide `dart:io` stdout/stderr. That made command
/// output unobservable except by spawning the compiled binary, which is why
/// `test/cli/commands_test.dart` drives `IOOverrides` instead of simply
/// reading what the command wrote.
///
/// `RunProcess` has always carried the streams (`runCli` already injects
/// capture streams into it for tests); the commands just ignored them. Routing
/// through the context closes that gap without adding a dotweave-specific
/// field to the vendored stricli port in `cli/router.dart`.
CliLogger loggerFor(RunContext context) {
  return createCliLogger(
    stdout: context.process.stdout,
    stderr: context.process.stderr,
  );
}
