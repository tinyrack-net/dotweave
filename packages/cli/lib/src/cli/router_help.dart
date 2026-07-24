// Help/usage rendering half of the stricli port (src/parameter/formatting.ts,
// src/parameter/flag/formatting.ts, src/parameter/positional/formatting.ts,
// src/routing/command/documentation.ts, src/routing/route-map/documentation.ts
// of @stricli/core).

part of 'router.dart';

/// Arguments threaded through help/usage rendering; mirror of the TS
/// `DocumentedTarget`/`formatHelp` argument object.
final class HelpFormattingArguments {
  const HelpFormattingArguments({
    required this.prefix,
    required this.config,
    required this.text,
    this.includeVersionFlag = false,
    this.includeArgumentEscapeSequenceFlag = false,
    this.includeHelpAllFlag = false,
    this.includeHidden = false,
    this.aliases = const [],
    this.ansiColor = false,
  });

  final List<String> prefix;
  final DocumentationConfig config;
  final ApplicationText text;
  final bool includeVersionFlag;
  final bool includeArgumentEscapeSequenceFlag;
  final bool includeHelpAllFlag;
  final bool includeHidden;
  final List<String> aliases;
  final bool ansiColor;

  HelpFormattingArguments withPrefix(List<String> prefix) {
    return HelpFormattingArguments(
      prefix: prefix,
      config: config,
      text: text,
      includeVersionFlag: includeVersionFlag,
      includeArgumentEscapeSequenceFlag: includeArgumentEscapeSequenceFlag,
      includeHelpAllFlag: includeHelpAllFlag,
      includeHidden: includeHidden,
      aliases: aliases,
      ansiColor: ansiColor,
    );
  }
}

/// Mirror of `formatForDisplay` (src/config.ts).
String _formatForDisplay(String flagName, DisplayCaseStyle displayCaseStyle) {
  if (displayCaseStyle == DisplayCaseStyle.convertCamelToKebab) {
    return convertCamelCaseToKebabCase(flagName);
  }
  return flagName;
}

/// Mirror of `formatAsNegated` (src/config.ts).
String _formatAsNegated(String flagName, DisplayCaseStyle displayCaseStyle) {
  if (displayCaseStyle == DisplayCaseStyle.convertCamelToKebab) {
    return 'no-${convertCamelCaseToKebabCase(flagName)}';
  }
  return 'no${flagName[0].toUpperCase()}${flagName.substring(1)}';
}

String _wrapRequiredFlag(String text) => '($text)';
String _wrapOptionalFlag(String text) => '[$text]';
String _wrapVariadicFlag(String text) => '$text...';
String _wrapRequiredParameter(String text) => '<$text>';
String _wrapOptionalParameter(String text) => '[<$text>]';
String _wrapVariadicParameter(String text) => '<$text>...';

/// Mirror of `formatUsageLineForParameters` (dist index.js:1714).
String _formatUsageLineForParameters(
  CommandParameters parameters,
  HelpFormattingArguments args,
) {
  final flagsUsage = <String>[];
  for (final entry in parameters.flags.entries) {
    final name = entry.key;
    final flag = entry.value;
    if (flag.hidden) {
      continue;
    }
    if (args.config.onlyRequiredInUsageLine && _isOptionalAtRuntime(flag)) {
      continue;
    }
    var displayName =
        args.config.caseStyle == DisplayCaseStyle.convertCamelToKebab
        ? '--${convertCamelCaseToKebabCase(name)}'
        : '--$name';
    if (parameters.aliases.isNotEmpty && args.config.useAliasInUsageLine) {
      final aliases = parameters.aliases.entries
          .where((aliasEntry) => aliasEntry.value == name)
          .toList();
      if (aliases.length == 1) {
        displayName = '-${aliases[0].key}';
      }
    }
    String usage;
    switch (flag) {
      case BooleanFlag():
        usage = displayName;
      case EnumFlag f when f.placeholder == null:
        usage = '$displayName ${f.values.join('|')}';
      case EnumFlag f:
        usage = '$displayName ${f.placeholder}';
      case ParsedFlag f:
        usage = '$displayName ${f.placeholder ?? 'value'}';
      case CounterFlag():
        usage = '$displayName value';
    }
    if (flag is ParsedFlag && flag.variadic) {
      flagsUsage.add(
        _isOptionalAtRuntime(flag)
            ? _wrapVariadicFlag(_wrapOptionalFlag(usage))
            : _wrapVariadicFlag(_wrapRequiredFlag(usage)),
      );
    } else if (_isOptionalAtRuntime(flag)) {
      flagsUsage.add(_wrapOptionalFlag(usage));
    } else {
      flagsUsage.add(_wrapRequiredFlag(usage));
    }
  }
  var positionalUsage = <String>[];
  final positional = parameters.positional;
  if (positional != null) {
    if (positional is ArrayPositionalParameters) {
      positionalUsage = [
        _wrapVariadicParameter(positional.parameter.placeholder ?? 'args'),
      ];
    } else {
      var params = (positional as TuplePositionalParameters).parameters;
      if (args.config.onlyRequiredInUsageLine) {
        params = params
            .where(
              (param) =>
                  !(param.optional ?? false) && param.defaultValue == null,
            )
            .toList();
      }
      positionalUsage = [
        for (var i = 0; i < params.length; i++)
          () {
            final param = params[i];
            final argName = param.placeholder ?? 'arg${i + 1}';
            return (param.optional ?? false) || param.defaultValue != null
                ? _wrapOptionalParameter(argName)
                : _wrapRequiredParameter(argName);
          }(),
      ];
    }
  }
  return [...args.prefix, ...flagsUsage, ...positionalUsage].join(' ');
}

final class _FlagHelpRow {
  const _FlagHelpRow({
    required this.aliases,
    required this.flagName,
    required this.brief,
    this.suffix,
    this.hidden = false,
  });

  final String aliases;
  final String flagName;
  final String brief;
  final String? suffix;
  final bool hidden;
}

/// Mirror of `formatDocumentationForFlagParameters` (dist index.js:1771).
List<String> _formatDocumentationForFlagParameters(
  Map<String, Flag> flags,
  Map<String, String> aliases,
  HelpFormattingArguments args,
) {
  final keywords = args.text.keywords;
  final briefs = args.text.briefs;
  final visibleFlags = flags.entries
      .where((entry) => !entry.value.hidden || args.includeHidden)
      .toList();
  final atLeastOneOptional = visibleFlags.any(
    (entry) => _isOptionalAtRuntime(entry.value),
  );
  final rows = <_FlagHelpRow>[];
  for (final entry in visibleFlags) {
    final name = entry.key;
    final flag = entry.value;
    final aliasStrings = aliases.entries
        .where((aliasEntry) => aliasEntry.value == name)
        .map((aliasEntry) => '-${aliasEntry.key}')
        .toList();
    var flagName = '--${_formatForDisplay(name, args.config.caseStyle)}';
    if (flag is BooleanFlag &&
        flag.defaultValue != false &&
        flag.withNegated != false) {
      final negatedFlagName = _formatAsNegated(name, args.config.caseStyle);
      flagName = '$flagName/--$negatedFlagName';
    }
    if (_isOptionalAtRuntime(flag)) {
      flagName = '[$flagName]';
    } else if (atLeastOneOptional) {
      flagName = ' $flagName';
    }
    if (flag is ParsedFlag && flag.variadic) {
      flagName = '$flagName...';
    }
    final suffixParts = <String>[];
    if (flag is EnumFlag) {
      suffixParts.add(flag.values.join('|'));
    }
    if (_hasDefault(flag)) {
      final defaultKeyword = args.ansiColor
          ? '\x1B[2m${keywords.defaultKeyword}\x1B[22m'
          : keywords.defaultKeyword;
      final rawDefault = _flagDefault(flag);
      String defaultValue;
      if (rawDefault is List<String>) {
        if (rawDefault.isEmpty) {
          defaultValue = '[]';
        } else {
          final separator = _variadicSeparator(flag) ?? ' ';
          defaultValue = rawDefault.join(separator);
        }
      } else {
        defaultValue = rawDefault == '' ? '""' : '$rawDefault';
      }
      suffixParts.add('$defaultKeyword $defaultValue');
    }
    final variadicSeparator = _variadicSeparator(flag);
    if (variadicSeparator != null) {
      final separatorKeyword = args.ansiColor
          ? '\x1B[2m${keywords.separator}\x1B[22m'
          : keywords.separator;
      suffixParts.add('$separatorKeyword $variadicSeparator');
    }
    final suffix = suffixParts.isNotEmpty
        ? '[${suffixParts.join(', ')}]'
        : null;
    rows.add(
      _FlagHelpRow(
        aliases: aliasStrings.join(' '),
        flagName: flagName,
        brief: flag.brief,
        suffix: suffix,
        hidden: flag.hidden,
      ),
    );
  }
  rows.add(
    _FlagHelpRow(
      aliases: '-h',
      flagName: atLeastOneOptional ? ' --help' : '--help',
      brief: briefs.help,
    ),
  );
  if (args.includeHelpAllFlag) {
    final helpAllFlagName = _formatForDisplay('helpAll', args.config.caseStyle);
    rows.add(
      _FlagHelpRow(
        aliases: '-H',
        flagName: atLeastOneOptional
            ? ' --$helpAllFlagName'
            : '--$helpAllFlagName',
        brief: briefs.helpAll,
        hidden: !args.config.alwaysShowHelpAllFlag,
      ),
    );
  }
  if (args.includeVersionFlag) {
    rows.add(
      _FlagHelpRow(
        aliases: '-v',
        flagName: atLeastOneOptional ? ' --version' : '--version',
        brief: briefs.version,
      ),
    );
  }
  if (args.includeArgumentEscapeSequenceFlag) {
    rows.add(
      _FlagHelpRow(
        aliases: '',
        flagName: atLeastOneOptional ? ' --' : '--',
        brief: briefs.argumentEscapeSequence,
      ),
    );
  }
  return formatRowsWithColumns(
    rows.map((row) {
      if (!args.ansiColor) {
        return [row.aliases, row.flagName, row.brief, row.suffix ?? ''];
      }
      return [
        row.hidden
            ? '\x1B[2m${row.aliases}\x1B[22m'
            : '\x1B[1m${row.aliases}\x1B[22m',
        row.hidden
            ? '\x1B[2m${row.flagName}\x1B[22m'
            : '\x1B[1m${row.flagName}\x1B[22m',
        row.hidden
            ? '\x1B[2;3m${row.brief}\x1B[22;23m'
            : '\x1B[;;3m${row.brief}\x1B[;;;23m',
        row.suffix ?? '',
      ];
    }).toList(),
    [' ', '  ', ' '],
  );
}

/// Mirror of `generateBuiltInFlagUsageLines`.
Iterable<String> _generateBuiltInFlagUsageLines(
  HelpFormattingArguments args,
) sync* {
  yield args.config.useAliasInUsageLine ? '-h' : '--help';
  if (args.includeHelpAllFlag) {
    final helpAllFlagName = _formatForDisplay('helpAll', args.config.caseStyle);
    yield args.config.useAliasInUsageLine ? '-H' : '--$helpAllFlagName';
  }
  if (args.includeVersionFlag) {
    yield args.config.useAliasInUsageLine ? '-v' : '--version';
  }
}

/// Mirror of `formatDocumentationForPositionalParameters` (dist index.js:1883).
List<String> _formatDocumentationForPositionalParameters(
  PositionalParameters positional,
  HelpFormattingArguments args,
) {
  if (positional is ArrayPositionalParameters) {
    final name = positional.parameter.placeholder ?? 'args';
    final argName = args.ansiColor ? '\x1B[1m$name...\x1B[22m' : '$name...';
    final brief = args.ansiColor
        ? '\x1B[3m${positional.parameter.brief}\x1B[23m'
        : positional.parameter.brief;
    return formatRowsWithColumns(
      [
        [argName, brief],
      ],
      ['  '],
    );
  }
  final keywords = args.text.keywords;
  final parameters = (positional as TuplePositionalParameters).parameters;
  final atLeastOneOptional = parameters.any((def) => def.optional ?? false);
  return formatRowsWithColumns(
    [
      for (var i = 0; i < parameters.length; i++)
        () {
          final def = parameters[i];
          var name = def.placeholder ?? 'arg${i + 1}';
          String? suffix;
          if (def.optional ?? false) {
            name = '[$name]';
          } else if (atLeastOneOptional) {
            name = ' $name';
          }
          final defaultValue = def.defaultValue;
          if (defaultValue != null && defaultValue.isNotEmpty) {
            final defaultKeyword = args.ansiColor
                ? '\x1B[2m${keywords.defaultKeyword}\x1B[22m'
                : keywords.defaultKeyword;
            suffix = '[$defaultKeyword $defaultValue]';
          }
          return [
            args.ansiColor ? '\x1B[1m$name\x1B[22m' : name,
            args.ansiColor ? '\x1B[3m${def.brief}\x1B[23m' : def.brief,
            suffix ?? '',
          ];
        }(),
    ],
    ['  ', ' '],
  );
}

/// Mirror of `generateCommandHelpLines` (dist index.js:1916).
Iterable<String> _generateCommandHelpLines(
  CommandParameters parameters,
  CommandDocs docs,
  HelpFormattingArguments args,
) sync* {
  final headers = args.text.headers;
  final prefix = args.prefix.join(' ');
  yield args.ansiColor ? '\x1B[4m${headers.usage}\x1B[24m' : headers.usage;
  yield '  ${_formatUsageLineForParameters(parameters, args)}';
  for (final line in _generateBuiltInFlagUsageLines(args)) {
    yield '  $prefix $line';
  }
  yield '';
  yield docs.fullDescription ?? docs.brief;
  if (args.aliases.isNotEmpty) {
    final aliasPrefix = args.prefix
        .sublist(0, args.prefix.length - 1)
        .join(' ');
    yield '';
    yield args.ansiColor
        ? '\x1B[4m${headers.aliases}\x1B[24m'
        : headers.aliases;
    for (final alias in args.aliases) {
      yield '  $aliasPrefix $alias';
    }
  }
  yield '';
  yield args.ansiColor ? '\x1B[4m${headers.flags}\x1B[24m' : headers.flags;
  for (final line in _formatDocumentationForFlagParameters(
    parameters.flags,
    parameters.aliases,
    args,
  )) {
    yield '  $line';
  }
  final positional =
      parameters.positional ?? const TuplePositionalParameters([]);
  if (positional is ArrayPositionalParameters ||
      (positional as TuplePositionalParameters).parameters.isNotEmpty) {
    yield '';
    yield args.ansiColor
        ? '\x1B[4m${headers.arguments}\x1B[24m'
        : headers.arguments;
    for (final line in _formatDocumentationForPositionalParameters(
      parameters.positional!,
      args,
    )) {
      yield '  $line';
    }
  }
}

/// Mirror of `generateRouteMapHelpLines` (dist index.js:2049).
Iterable<String> _generateRouteMapHelpLines(
  Map<String, RoutingTarget> routes,
  RouteMapDocs docs,
  HelpFormattingArguments args,
) sync* {
  final headers = args.text.headers;
  final hideRoute = docs.hideRoute;
  yield args.ansiColor ? '\x1B[4m${headers.usage}\x1B[24m' : headers.usage;
  for (final entry in routes.entries) {
    if (!(hideRoute[entry.key] ?? false) || args.includeHidden) {
      final externalRouteName =
          args.config.caseStyle == DisplayCaseStyle.convertCamelToKebab
          ? convertCamelCaseToKebabCase(entry.key)
          : entry.key;
      yield '  ${entry.value.formatUsageLine(args.withPrefix([...args.prefix, externalRouteName]))}';
    }
  }
  final prefix = args.prefix.join(' ');
  for (final line in _generateBuiltInFlagUsageLines(args)) {
    yield '  $prefix $line';
  }
  yield '';
  yield docs.fullDescription ?? docs.brief;
  if (args.aliases.isNotEmpty) {
    final aliasPrefix = args.prefix
        .sublist(0, args.prefix.length - 1)
        .join(' ');
    yield '';
    yield args.ansiColor
        ? '\x1B[4m${headers.aliases}\x1B[24m'
        : headers.aliases;
    for (final alias in args.aliases) {
      yield '  $aliasPrefix $alias';
    }
  }
  yield '';
  yield args.ansiColor ? '\x1B[4m${headers.flags}\x1B[24m' : headers.flags;
  for (final line in _formatDocumentationForFlagParameters(
    const {},
    const {},
    args,
  )) {
    yield '  $line';
  }
  yield '';
  yield args.ansiColor
      ? '\x1B[4m${headers.commands}\x1B[24m'
      : headers.commands;
  final visibleRoutes = routes.entries.where(
    (entry) => !(hideRoute[entry.key] ?? false) || args.includeHidden,
  );
  final rows = visibleRoutes.map((entry) {
    return (
      routeName: _formatForDisplay(entry.key, args.config.caseStyle),
      brief: entry.value.brief,
      hidden: hideRoute[entry.key] ?? false,
    );
  }).toList();
  final formattedRows = formatRowsWithColumns(
    rows.map((row) {
      if (!args.ansiColor) {
        return [row.routeName, row.brief];
      }
      return [
        row.hidden
            ? '\x1B[2m${row.routeName}\x1B[22m'
            : '\x1B[1m${row.routeName}\x1B[22m',
        row.hidden
            ? '\x1B[2;3m${row.brief}\x1B[22;23m'
            : '\x1B[;;3m${row.brief}\x1B[;;;23m',
      ];
    }).toList(),
    ['  '],
  );
  for (final line in formattedRows) {
    yield '  $line';
  }
}
