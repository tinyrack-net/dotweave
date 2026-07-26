// Dart port of `packages/cli/src/cli/autocomplete.ts`.

import 'package:dotweave/src/config/constants.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

/// dotweave's binding of the framework's shell-script generators. The scripts
/// themselves are generic; only the executable name and the hidden subcommand
/// they call are dotweave's.
final CompletionScripts completionScripts = CompletionScripts(
  executableName: AppConstants.autocomplete.cliCommandName,
  completeSubcommand: AppConstants.autocomplete.completeSubcommand,
);

Application? _application;

void setApplication(Application app) {
  _application = app;
}

Command _buildAutocompleteScriptCommand(String shell, String script) {
  return buildCommand(
    docs: CommandDocs(
      brief: 'Print $shell autocomplete script',
      fullDescription:
          'Emit a $shell autocomplete script for use with `eval "\$(dotweave autocomplete $shell)"`.',
    ),
    func: (context, flags, positional) {
      context.process.stdout.write(script);
      return null;
    },
    parameters: const CommandParameters(),
  );
}

final Command _bashAutocompleteCommand = _buildAutocompleteScriptCommand(
  'bash',
  completionScripts.bash,
);
final Command _zshAutocompleteCommand = _buildAutocompleteScriptCommand(
  'zsh',
  completionScripts.zsh,
);
final Command _fishAutocompleteCommand = _buildAutocompleteScriptCommand(
  'fish',
  completionScripts.fish,
);
final Command _powershellAutocompleteCommand = _buildAutocompleteScriptCommand(
  'powershell',
  completionScripts.powershell,
);

final Command _completeCommand = buildCommand(
  docs: const CommandDocs(brief: 'Internal completion command'),
  func: (context, flags, positional) async {
    final application = _application;

    if (application == null) {
      return null;
    }

    final completions = await proposeCompletions(
      application,
      completionScripts.resolveCompletionInputs(positional.cast<String>()),
      context,
    );

    if (completions.isEmpty) {
      return null;
    }

    final lines = completions
        .map(
          (c) =>
              c.brief.isNotEmpty ? '${c.completion}\t${c.brief}' : c.completion,
        )
        .join('\n');

    context.process.stdout.write('$lines\n');
    return null;
  },
  parameters: const CommandParameters(
    positional: ArrayPositionalParameters(
      minimum: 0,
      parameter: PositionalParameter(
        brief: 'Completion input token',
        parse: stringParser,
        placeholder: 'input',
      ),
    ),
  ),
);

({RouteMap autocompleteRoute, Command completeCommand})
buildAutocompleteRoute() {
  return (
    autocompleteRoute: buildRouteMap(
      docs: const RouteMapDocs(
        brief: 'Print shell autocomplete scripts',
        fullDescription:
            'Emit shell-specific autocomplete scripts for use with eval-based shell setup.',
      ),
      routes: {
        'bash': _bashAutocompleteCommand,
        'fish': _fishAutocompleteCommand,
        'powershell': _powershellAutocompleteCommand,
        'zsh': _zshAutocompleteCommand,
      },
    ),
    completeCommand: _completeCommand,
  );
}
