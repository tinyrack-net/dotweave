// Dart port of `src/cli/autocomplete.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/config/constants.dart';

/// dotweave's binding of the framework's shell-script generators. The scripts
/// themselves are generic; only the executable name and the hidden subcommand
/// they call are dotweave's.
final CompletionScripts completionScripts = CompletionScripts(
  executableName: AppConstants.autocomplete.cliCommandName,
  completeSubcommand: AppConstants.autocomplete.completeSubcommand,
);

Application<ApplicationContext>? _application;

void setApplication(Application<ApplicationContext> app) {
  _application = app;
}

Command<ApplicationContext> _buildAutocompleteScriptCommand(
  String shell,
  String script,
) {
  return buildCommand(
    docs: CommandDocs(
      brief: 'Print $shell autocomplete script',
      fullDescription:
          'Emit a $shell autocomplete script for use with `eval "\$(dotweave autocomplete $shell)"`.',
    ),
    func: (context, flags, args) {
      context.process.stdout.write(script);
    },
    parameters: CommandParameters(
      flags: FlagSet<NoFlags, ApplicationContext>.none(),
      positional: PositionalSet.none(),
    ),
  );
}

final Command<ApplicationContext> _bashAutocompleteCommand =
    _buildAutocompleteScriptCommand('bash', completionScripts.bash);
final Command<ApplicationContext> _zshAutocompleteCommand =
    _buildAutocompleteScriptCommand('zsh', completionScripts.zsh);
final Command<ApplicationContext> _fishAutocompleteCommand =
    _buildAutocompleteScriptCommand('fish', completionScripts.fish);
final Command<ApplicationContext> _powershellAutocompleteCommand =
    _buildAutocompleteScriptCommand('powershell', completionScripts.powershell);

final Command<ApplicationContext> _completeCommand = buildCommand(
  docs: const CommandDocs(brief: 'Internal completion command'),
  func: (context, flags, args) async {
    final application = _application;

    if (application == null) {
      return;
    }

    final completions = await proposeCompletions(
      application,
      completionScripts.resolveCompletionInputs(args),
      RunContext.direct(context),
    );

    if (completions.isEmpty) {
      return;
    }

    final lines = completions
        .map(
          (c) =>
              c.brief.isNotEmpty ? '${c.completion}\t${c.brief}' : c.completion,
        )
        .join('\n');

    context.process.stdout.write('$lines\n');
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.array(
      Positional.required<String, ApplicationContext>(
        brief: 'Completion input token',
        parse: stringParser,
        placeholder: 'input',
      ),
      minimum: 0,
    ),
  ),
);

({
  RouteMap<ApplicationContext> autocompleteRoute,
  Command<ApplicationContext> completeCommand,
})
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
