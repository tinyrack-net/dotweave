// Dart port of `packages/cli/src/cli/skill/install.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
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

final Command<ApplicationContext> skillInstallCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Install the bundled dotweave agent skill',
    fullDescription:
        "Install Dotweave's bundled portable agent skill into the specified skills directory.",
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);
    final result = await installDotweaveSkill(
      SkillInstallRequest(
        directory: args,
        dryRun: flags.dryRun ?? false,
        force: flags.force ?? false,
      ),
    );
    final message = _formatInstallMessage(result.action);

    if (result.dryRun) {
      logger.info(message);
    } else {
      logger.success(message);
    }

    logger.kv('target', result.targetPath);
  },
  parameters: CommandParameters(
    flags:
        FlagSet.one(
              BooleanFlag.optional<ApplicationContext>(
                name: 'dryRun',
                brief: 'Report the install target without writing files',
              ),
            )
            .and(
              BooleanFlag.optional<ApplicationContext>(
                name: 'force',
                brief: 'Overwrite an existing dotweave skill',
              ),
            )
            .map((v) => (dryRun: v.$1, force: v.$2)),
    positional: PositionalSet.one(
      Positional.required<String, ApplicationContext>(
        brief: 'Skills root directory',
        parse: stringParser,
        placeholder: 'directory',
      ),
    ),
  ),
);
