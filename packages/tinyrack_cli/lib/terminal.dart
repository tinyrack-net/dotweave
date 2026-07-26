/// Terminal output for command-line applications: a levelled logger, a
/// spinner that degrades to plain lines off a TTY, and a colour theme that
/// honours `NO_COLOR`, `FORCE_COLOR`, and `CI`.
///
/// Writes through [WriteStream], the same abstraction the command framework
/// uses, so a single captured stream observes all output in tests.
library;

export 'src/env.dart' show EnvLookup, lookupPlatformEnv;
export 'src/terminal/logger.dart';
export 'src/terminal/spinner.dart';
export 'src/terminal/theme.dart';
export 'src/write_stream.dart';
