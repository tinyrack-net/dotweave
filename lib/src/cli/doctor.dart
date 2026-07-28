// Dart port of `src/cli/doctor.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:cliweave/terminal.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/doctor.dart';
import 'package:dotweave/src/util/error.dart';

String _remapCheckIdForDisplay(String checkId) {
  switch (checkId) {
    case 'age':
      return 'identity';
    case 'local-paths':
      return 'local';
    default:
      return checkId;
  }
}

String _stripTrailingPeriod(String value) {
  return value.endsWith('.') ? value.substring(0, value.length - 1) : value;
}

String _formatCheckIcon(DoctorCheckLevel level) {
  // The TS switch is exhaustive over the `"ok" | "warn" | "fail"` union; the
  // Dart typedef is a plain String, so `fail` doubles as the default case.
  return switch (level) {
    'ok' => color.success(SYMBOLS.success),
    'warn' => color.warn(SYMBOLS.warn),
    _ => color.error(SYMBOLS.error),
  };
}

/// Mirror of the TS `DotweaveError & { exitCode: number }` cast: a doctor
/// failure that drives process exit code 1 through `resolveExitCode`.
class _DoctorIssuesError extends DotweaveError implements CommandExitCode {
  _DoctorIssuesError(super.message);

  @override
  int get exitCode => 1;
}

final Command<ApplicationContext> doctorCommand = buildCommand(
  docs: const CommandDocs(
    brief:
        'Check sync directory, config, age identity, and tracked local paths',
    fullDescription:
        'Run health checks for the local sync setup, including repository availability, config validity, age identity configuration, and whether tracked local paths still exist where dotweave expects them.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);

    final spin = logger.spinner('Running checks...');
    final result = await runDoctorChecks();
    spin.stop();

    var okCount = 0;
    var warningCount = 0;
    var failureCount = 0;

    for (final check in result.checks) {
      if (check.level == 'ok') {
        okCount += 1;
      } else if (check.level == 'warn') {
        warningCount += 1;
      } else {
        failureCount += 1;
      }
    }

    final summary = color.dim(
      '($okCount ok · $warningCount warnings · $failureCount failures)',
    );

    if (result.hasFailures) {
      logger.fail('Doctor found issues $summary');
    } else if (result.hasWarnings) {
      logger.warn('Doctor completed with warnings $summary');
    } else {
      logger.success('Doctor passed $summary');
    }

    final nonOkChecks = result.checks
        .where((check) => check.level != 'ok')
        .toList();

    if (nonOkChecks.isNotEmpty) {
      for (final check in nonOkChecks.take(3)) {
        logger.log(
          '  ${_formatCheckIcon(check.level)} ${_remapCheckIdForDisplay(check.checkId)} — ${_stripTrailingPeriod(check.detail)}',
        );
      }
      if (nonOkChecks.length > 3) {
        logger.log(color.dim('  ... ${nonOkChecks.length - 3} more issues'));
      }
    }

    if (result.hasFailures) {
      throw _DoctorIssuesError('Doctor found issues.');
    }
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.none(),
  ),
);
