// Dart port of `packages/cli/src/cli/skill/install.ts`.

import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/skill_install.dart';

String _formatInstallMessage(String action) {
  switch (action) {
    case 'would-install':
      return 'Would install dotweave skill';
    case 'would-overwrite':
      return 'Would overwrite dotweave skill';
    case 'overwritten':
      return 'Overwrote dotweave skill';
    default:
      return 'Installed dotweave skill';
  }
}

final Command skillInstallCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Install the bundled dotweave agent skill',
    fullDescription:
        "Install Dotweave's bundled portable agent skill into the specified skills directory.",
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);
    final result = await installDotweaveSkill(
      SkillInstallRequest(
        directory: positional[0] as String,
        dryRun: flags['dryRun'] as bool? ?? false,
        force: flags['force'] as bool? ?? false,
      ),
    );
    final message = _formatInstallMessage(result.action);

    if (result.dryRun) {
      logger.info(message);
    } else {
      logger.success(message);
    }

    logger.kv('target', result.targetPath);
    return null;
  },
  parameters: const CommandParameters(
    flags: {
      'dryRun': BooleanFlag(
        brief: 'Report the install target without writing files',
        optional: true,
      ),
      'force': BooleanFlag(
        brief: 'Overwrite an existing dotweave skill',
        optional: true,
      ),
    },
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Skills root directory',
        parse: stringParser,
        placeholder: 'directory',
      ),
    ]),
  ),
);
