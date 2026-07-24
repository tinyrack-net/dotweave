import 'error.dart';

/// Result of hand-rolled command-line parsing.
class ParsedArgs {
  const ParsedArgs({
    required this.options,
    required this.flags,
    required this.positionals,
  });

  final Map<String, String> options;
  final Set<String> flags;
  final List<String> positionals;

  String? option(String name) => options[name];

  String requireOption(String name) {
    final value = options[name];

    if (value == null) {
      throw ToolException('Missing required option --$name');
    }

    return value;
  }

  bool flag(String name) => flags.contains(name);
}

/// Parses [args] into options (kebab-case, `--name value` or `--name=value`),
/// boolean flags, and positionals. Unknown options are rejected.
ParsedArgs parseArgs(
  List<String> args, {
  Set<String> valueOptions = const {},
  Set<String> booleanFlags = const {},
  Map<String, String> aliases = const {},
}) {
  final options = <String, String>{};
  final flags = <String>{};
  final positionals = <String>[];
  var index = 0;

  while (index < args.length) {
    final arg = args[index];

    if (arg.startsWith('--')) {
      var name = arg.substring(2);
      String? inlineValue;
      final equalsIndex = name.indexOf('=');

      if (equalsIndex >= 0) {
        inlineValue = name.substring(equalsIndex + 1);
        name = name.substring(0, equalsIndex);
      }

      name = aliases[name] ?? name;

      if (booleanFlags.contains(name)) {
        if (inlineValue != null) {
          throw ToolException('Flag --$name does not take a value');
        }

        flags.add(name);
      } else if (valueOptions.contains(name)) {
        if (inlineValue != null) {
          options[name] = inlineValue;
        } else {
          index++;

          if (index >= args.length) {
            throw ToolException('Missing value for --$name');
          }

          options[name] = args[index];
        }
      } else {
        throw ToolException('Unknown option: --$name');
      }
    } else if (arg.startsWith('-') && arg.length > 1) {
      final name = aliases[arg.substring(1)];

      if (name == null) {
        throw ToolException('Unknown option: $arg');
      }

      if (booleanFlags.contains(name)) {
        flags.add(name);
      } else if (valueOptions.contains(name)) {
        index++;

        if (index >= args.length) {
          throw ToolException('Missing value for --$name');
        }

        options[name] = args[index];
      } else {
        throw ToolException('Unknown option: $arg');
      }
    } else {
      positionals.add(arg);
    }

    index++;
  }

  return ParsedArgs(options: options, flags: flags, positionals: positionals);
}
