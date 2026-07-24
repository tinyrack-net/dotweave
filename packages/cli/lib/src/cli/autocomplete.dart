// Dart port of `packages/cli/src/cli/autocomplete.ts`.

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/autocomplete.dart';

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
  bashAutocompleteScript,
);
final Command _zshAutocompleteCommand = _buildAutocompleteScriptCommand(
  'zsh',
  zshAutocompleteScript,
);
final Command _fishAutocompleteCommand = _buildAutocompleteScriptCommand(
  'fish',
  fishAutocompleteScript,
);
final Command _powershellAutocompleteCommand = _buildAutocompleteScriptCommand(
  'powershell',
  powershellAutocompleteScript,
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
      resolveCompletionInputs(positional.cast<String>()),
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
