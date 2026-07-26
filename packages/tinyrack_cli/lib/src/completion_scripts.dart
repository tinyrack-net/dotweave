import 'package:tinyrack_cli/src/env.dart';

// Shell-side half of the completion story. The framework computes candidates
// (`proposeCompletions`); these scripts are what a shell sources so that
// pressing Tab calls back into the application to ask for them.
//
// Every literal shell `$` is written `\$`, and literal `\t`/`\n` escapes as
// `\\t`/`\\n`, because the whole body is a Dart interpolated string.

/// Shell characters that are not valid in a POSIX function name.
final RegExp _unsafeFunctionNameChars = RegExp('[^A-Za-z0-9_]');

String _defaultFunctionPrefix(String executableName) {
  return '__${executableName.replaceAll(_unsafeFunctionNameChars, '_')}';
}

/// Generates shell completion scripts for a command-line application.
///
/// Each script collects the current command line and runs
/// `<executableName> <completeSubcommand> <tokens...>`, which the application
/// must answer with one `completion<TAB>description` line per candidate —
/// exactly what the hidden completion command built around
/// [proposeCompletions] emits.
///
/// Wire it up by registering a hidden route for [completeSubcommand] and
/// printing [bash], [zsh], [fish], or [powershell] from a user-facing command:
///
/// ```dart
/// final scripts = CompletionScripts(executableName: 'example');
/// // eval "$(example completion zsh)"
/// print(scripts.zsh);
/// ```
class CompletionScripts {
  /// Builds the script set for [executableName].
  ///
  /// [functionPrefix] names the shell functions the scripts define; it
  /// defaults to `__<executableName>` with any character that is illegal in a
  /// POSIX function name replaced by `_`, so an executable called `my-cli`
  /// yields `__my_cli_complete` rather than an unparseable `__my-cli_complete`.
  CompletionScripts({
    required this.executableName,
    this.completeSubcommand = '__complete',
    String? functionPrefix,
  }) : functionPrefix =
           functionPrefix ?? _defaultFunctionPrefix(executableName);

  /// Name the application is invoked as, e.g. `git`.
  final String executableName;

  /// Hidden subcommand the scripts call to ask for candidates.
  final String completeSubcommand;

  /// Prefix for the shell functions the scripts define.
  final String functionPrefix;

  String get _completeCommand => '$executableName $completeSubcommand';

  String get _completionFunctionName => '${functionPrefix}_complete';

  String get _ensureFunctionName => '${functionPrefix}_ensure_completion';

  /// Script for bash, to be sourced or `eval`'d.
  String get bash =>
      '''
$_completionFunctionName() {
  local -a inputs
  local rawCompletions completion
  inputs=("\${COMP_WORDS[@]}")
  if [[ \${#inputs[@]} -eq 1 && \${COMP_CWORD:-0} -eq 0 && "\${inputs[0]}" == "$executableName" ]]; then
    inputs+=("")
  elif [[ \${COMP_CWORD:-0} -ge \${#inputs[@]} ]]; then
    inputs+=("")
  fi
  if ! rawCompletions="\$(env -u COMP_LINE $_completeCommand "\${inputs[@]}")"; then
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
complete -o default -o nospace -F $_completionFunctionName $executableName
''';

  /// Script for PowerShell, to be dot-sourced or added to `\$PROFILE`.
  String get powershell =>
      '''
Register-ArgumentCompleter -Native -CommandName $executableName -ScriptBlock {
  param(\$wordToComplete, \$commandAst, \$cursorPosition)
  \$commandLine = \$commandAst.ToString()
  \$inputs = \$commandLine.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
  if (\$cursorPosition -gt \$commandLine.Length -or (\$cursorPosition -ge \$commandLine.Length -and \$commandLine.EndsWith(' '))) {
    \$inputs += ''
  }
  \$rawCompletions = & $_completeCommand \$inputs 2>\$null
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

  /// Script for fish, to be sourced or placed in `completions/`.
  String get fish =>
      '''
function $_completionFunctionName
    set -l tokens (commandline -opc)
    set -l current (commandline -ct)

    if test -z "\$current"
        set tokens \$tokens ""
    else if test (count \$tokens) -eq 0; or test "\$tokens[-1]" != "\$current"
        set tokens \$tokens \$current
    end

    command $_completeCommand \$tokens 2>/dev/null | while read -l line
        set -l parts (string split -m 1 \\t -- \$line)
        if test (count \$parts) -gt 1
            printf '%s\\t%s\\n' \$parts[1] \$parts[2]
        else
            printf '%s\\n' \$parts[1]
        end
    end
end
complete -c $executableName -f -a '($_completionFunctionName)'
''';

  /// Script for zsh, to be sourced or `eval`'d.
  String get zsh =>
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
  if (( CURRENT == 1 && \${#inputs[@]} == 1 )) && [[ "\${inputs[1]}" == "$executableName" ]]; then
    inputs+=("")
  elif (( CURRENT > \${#inputs[@]} )); then
    inputs+=("")
  fi
  if ! rawCompletions="\$(env -u COMP_LINE $_completeCommand "\${inputs[@]}")"; then
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
compdef $_completionFunctionName $executableName

$_ensureFunctionName() {
  if (( \$+functions[compdef] )) && [[ "\${_comps[$executableName]}" != $_completionFunctionName ]]; then
    compdef $_completionFunctionName $executableName
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd $_ensureFunctionName
''';

  bool _isExecutableToken(String input) {
    final normalizedInput = input.replaceAll('\\', '/').split('/').last;

    return normalizedInput == executableName ||
        normalizedInput == '$executableName.exe';
  }

  List<String> _dropLeadingExecutable(List<String> inputs) {
    final firstInput = inputs.isEmpty ? null : inputs.first;

    if (firstInput == null || !_isExecutableToken(firstInput)) {
      return [...inputs];
    }

    return inputs.sublist(1);
  }

  /// Normalizes the tokens a shell handed to the completion subcommand.
  ///
  /// Prefers `COMP_LINE` when the shell set it, since it preserves the raw
  /// line including a trailing space (which means "start a new word"), and
  /// drops a leading executable token so the remaining inputs line up with the
  /// application's own argument list. Pass [readEnv] to read the environment
  /// from somewhere other than the process.
  List<String> resolveCompletionInputs(
    List<String> inputs, {
    EnvLookup? readEnv,
  }) {
    final completionLine = (readEnv ?? lookupPlatformEnv)('COMP_LINE');

    if (completionLine == null) {
      return _dropLeadingExecutable(inputs);
    }

    final trimmedStart = completionLine.trimLeft();

    if (trimmedStart == '') {
      return [];
    }

    return _dropLeadingExecutable(trimmedStart.split(RegExp(r'\s+')));
  }
}
