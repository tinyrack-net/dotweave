// Dart port of `packages/cli/src/services/autocomplete.ts`.
//
// The shell completion scripts below must stay byte-for-byte identical to the
// TS template literals (e2e shell smoke tests source the emitted text), so
// every literal shell `$` is written as `\$` and every literal `\t`/`\n`
// escape as `\\t`/`\\n`.

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/lib/env.dart';

const String _completionFunctionName = '__dotweave_complete';
const String _ensureFunctionName = '__dotweave_ensure_completion';

final String bashAutocompleteScript =
    '''
$_completionFunctionName() {
  local -a inputs
  local rawCompletions completion
  inputs=("\${COMP_WORDS[@]}")
  if [[ \${#inputs[@]} -eq 1 && \${COMP_CWORD:-0} -eq 0 && "\${inputs[0]}" == "${AppConstants.autocomplete.cliCommandName}" ]]; then
    inputs+=("")
  elif [[ \${COMP_CWORD:-0} -ge \${#inputs[@]} ]]; then
    inputs+=("")
  fi
  if ! rawCompletions="\$(env -u COMP_LINE ${AppConstants.autocomplete.command} "\${inputs[@]}")"; then
    return 1
  fi

  COMPREPLY=()
  if [[ -z "\$rawCompletions" ]]; then
    return 0
  fi

  local IFS_TAB word desc
  IFS_TAB=\$'\\t'
  local maxLen=0
  local -a words descs
  while IFS= read -r completion; do
    word="\${completion%%"\$IFS_TAB"*}"
    if [[ "\$completion" == *"\$IFS_TAB"* ]]; then
      desc="\${completion#*"\$IFS_TAB"}"
    else
      desc=""
    fi
    words+=("\$word")
    descs+=("\$desc")
    if (( \${#word} > maxLen )); then
      maxLen=\${#word}
    fi
  done <<< "\$rawCompletions"

  if (( \${#words[@]} > 1 )); then
    local -a display
    local i
    for (( i=0; i<\${#words[@]}; i++ )); do
      if [[ -n "\${descs[i]}" ]]; then
        printf -v pad "%-\${maxLen}s" "\${words[i]}"
        display+=("\$pad -- \${descs[i]}")
      else
        display+=("\${words[i]}")
      fi
    done
    printf '%s\\n' "\${display[@]}" >&2
  fi

  for word in "\${words[@]}"; do
    if [[ "\$word" == */ ]]; then
      COMPREPLY+=("\$word")
    else
      COMPREPLY+=("\${word} ")
    fi
  done

  return 0
}
complete -o default -o nospace -F $_completionFunctionName ${AppConstants.autocomplete.cliCommandName}
''';

final String powershellAutocompleteScript =
    '''
Register-ArgumentCompleter -Native -CommandName ${AppConstants.autocomplete.cliCommandName} -ScriptBlock {
  param(\$wordToComplete, \$commandAst, \$cursorPosition)
  \$commandLine = \$commandAst.ToString()
  \$inputs = \$commandLine.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
  if (\$cursorPosition -gt \$commandLine.Length -or (\$cursorPosition -ge \$commandLine.Length -and \$commandLine.EndsWith(' '))) {
    \$inputs += ''
  }
  \$rawCompletions = & ${AppConstants.autocomplete.command.replaceFirst(' ', ' ')} \$inputs 2>\$null
  if (-not \$rawCompletions) { return }
  foreach (\$line in \$rawCompletions) {
    \$parts = \$line.Split([char]9, 2)
    \$word = \$parts[0]
    \$desc = if (\$parts.Length -gt 1) { \$parts[1] } else { '' }
    \$type = if (\$word.EndsWith('/')) {
      [System.Management.Automation.CompletionResultType]::ParameterValue
    } else {
      [System.Management.Automation.CompletionResultType]::ParameterValue
    }
    [System.Management.Automation.CompletionResult]::new(\$word, \$word, \$type, \$(if (\$desc) { \$desc } else { \$word }))
  }
}
''';

final String fishAutocompleteScript =
    '''
function $_completionFunctionName
    set -l tokens (commandline -opc)
    set -l current (commandline -ct)

    if test -z "\$current"
        set tokens \$tokens ""
    else if test (count \$tokens) -eq 0; or test "\$tokens[-1]" != "\$current"
        set tokens \$tokens \$current
    end

    command ${AppConstants.autocomplete.command} \$tokens 2>/dev/null | while read -l line
        set -l parts (string split -m 1 \\t -- \$line)
        if test (count \$parts) -gt 1
            printf '%s\\t%s\\n' \$parts[1] \$parts[2]
        else
            printf '%s\\n' \$parts[1]
        end
    end
end
complete -c ${AppConstants.autocomplete.cliCommandName} -f -a '($_completionFunctionName)'
''';

final String zshAutocompleteScript =
    '''
if ! (( \$+functions[compdef] )); then
  autoload -Uz compinit
  compinit -u
fi

$_completionFunctionName() {
  emulate -L zsh
  local -a directories inputs plainCompletions
  local rawCompletions
  inputs=("\${words[@]}")
  if (( CURRENT == 1 && \${#inputs[@]} == 1 )) && [[ "\${inputs[1]}" == "${AppConstants.autocomplete.cliCommandName}" ]]; then
    inputs+=("")
  elif (( CURRENT > \${#inputs[@]} )); then
    inputs+=("")
  fi
  if ! rawCompletions="\$(env -u COMP_LINE ${AppConstants.autocomplete.command} "\${inputs[@]}")"; then
    return 1
  fi

  if [[ -z "\$rawCompletions" ]]; then
    return 0
  fi

  directories=()
  plainCompletions=()
  local -a plainDisplays dirDisplays
  plainDisplays=()
  dirDisplays=()
  local IFS_TAB completion="" word desc
  IFS_TAB=\$'\\t'
  for completion in "\${(@f)rawCompletions}"; do
    word="\${completion%%"\$IFS_TAB"*}"
    if [[ "\$completion" == *"\$IFS_TAB"* ]]; then
      desc="\${completion#*"\$IFS_TAB"}"
    else
      desc=""
    fi
    if [[ "\$word" == */ ]]; then
      directories+=("\$word")
      if [[ -n "\$desc" ]]; then
        dirDisplays+=("\$word -- \$desc")
      else
        dirDisplays+=("\$word")
      fi
    else
      plainCompletions+=("\$word")
      if [[ -n "\$desc" ]]; then
        plainDisplays+=("\$word -- \$desc")
      else
        plainDisplays+=("\$word")
      fi
    fi
  done
  if (( \${#plainCompletions[@]} > 0 )); then
    compadd -Q -l -d plainDisplays -- "\${plainCompletions[@]}"
  fi
  if (( \${#directories[@]} > 0 )); then
    compadd -Q -S "" -l -d dirDisplays -- "\${directories[@]}"
  fi
}
compdef $_completionFunctionName ${AppConstants.autocomplete.cliCommandName}

$_ensureFunctionName() {
  if (( \$+functions[compdef] )) && [[ "\${_comps[${AppConstants.autocomplete.cliCommandName}]}" != $_completionFunctionName ]]; then
    compdef $_completionFunctionName ${AppConstants.autocomplete.cliCommandName}
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd $_ensureFunctionName
''';

bool _isCliCommandToken(String input) {
  final normalizedInput = input.replaceAll('\\', '/').split('/').last;

  return normalizedInput == AppConstants.autocomplete.cliCommandName ||
      normalizedInput == '${AppConstants.autocomplete.cliCommandName}.exe';
}

List<String> _normalizeCompletionInputs(List<String> inputs) {
  final firstInput = inputs.isEmpty ? null : inputs.first;

  if (firstInput == null || !_isCliCommandToken(firstInput)) {
    return [...inputs];
  }

  return inputs.sublist(1);
}

/// Mirror of `resolveCompletionInputs`; the TS module reads `process.env`
/// directly, the Dart port takes an injectable [Env] (defaulting to the
/// process environment) as the seam replacing the TS tests' `vi.stubEnv`.
List<String> resolveCompletionInputs(List<String> inputs, {Env? env}) {
  final environment = env ?? ENV;
  final completionLine = environment['COMP_LINE'];

  if (completionLine == null) {
    return _normalizeCompletionInputs(inputs);
  }

  final trimmedStart = completionLine.trimLeft();

  if (trimmedStart == '') {
    return [];
  }

  final completionInputs = trimmedStart.split(RegExp(r'\s+'));

  return _normalizeCompletionInputs(completionInputs);
}
