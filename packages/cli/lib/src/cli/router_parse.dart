// Argument-scanning half of the stricli port: case-style conversion,
// Damerau-Levenshtein suggestions, scanner errors, and the argument scanner
// (src/util/case-style.ts, src/util/distance.ts, src/parameter/scanner.ts,
// src/parameter/parser/*.ts of @stricli/core).

part of 'router.dart';

// ---------------------------------------------------------------------------
// Built-in parsers (src/parameter/parser)
// ---------------------------------------------------------------------------

/// Mirror of stricli `booleanParser` (strict true/false).
bool booleanParser(String input) {
  switch (input.toLowerCase()) {
    case 'true':
      return true;
    case 'false':
      return false;
  }
  throw FormatException('Cannot convert $input to a boolean');
}

const Set<String> _truthyValues = {'true', 't', 'yes', 'y', 'on', '1', ''};
const Set<String> _falsyValues = {'false', 'f', 'no', 'n', 'off', '0'};

/// Mirror of stricli `looseBooleanParser`.
bool looseBooleanParser(String input) {
  final value = input.toLowerCase();
  if (_truthyValues.contains(value)) {
    return true;
  }
  if (_falsyValues.contains(value)) {
    return false;
  }
  throw FormatException('Cannot convert $input to a boolean');
}

/// Mirror of stricli `numberParser` (JS `Number(input)` semantics are
/// approximated with [num.tryParse]; only counters reach this in dotweave).
num numberParser(String input) {
  final value = num.tryParse(input);
  if (value == null) {
    throw FormatException('Cannot convert $input to a number');
  }
  return value;
}

// ---------------------------------------------------------------------------
// Case style conversion (src/util/case-style.ts)
// ---------------------------------------------------------------------------

/// Mirror of `convertKebabCaseToCamelCase`.
String convertKebabCaseToCamelCase(String str) {
  return str.replaceAllMapped(RegExp('-.'), (match) {
    return match.group(0)![1].toUpperCase();
  });
}

/// Mirror of `convertCamelCaseToKebabCase`.
String convertCamelCaseToKebabCase(String name) {
  final buffer = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final char = name[i];
    final upper = char.toUpperCase();
    final lower = char.toLowerCase();
    if (i == 0 || upper != char || upper == lower) {
      buffer.write(char);
    } else {
      buffer.write('-$lower');
    }
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Damerau-Levenshtein distance (src/util/distance.ts)
// ---------------------------------------------------------------------------

class _SparseMatrix {
  _SparseMatrix(this.defaultValue);

  final double defaultValue;
  final Map<String, double> _values = {};

  double get(int i, int j) => _values['$i,$j'] ?? defaultValue;

  void set(double value, int i, int j) {
    _values['$i,$j'] = value;
  }
}

/// Mirror of `damerauLevenshtein` (weighted, threshold-limited).
double damerauLevenshtein(String a, String b, DistanceOptions options) {
  final threshold = options.threshold.toDouble();
  final weights = options.weights;
  if (a == b) {
    return 0;
  }
  final lengthDiff = (a.length - b.length).abs();
  if (lengthDiff > threshold) {
    return double.infinity;
  }
  final matrix = _SparseMatrix(double.infinity);
  matrix.set(0, -1, -1);
  for (var j = 0; j < b.length; ++j) {
    matrix.set((j + 1) * weights.insertion.toDouble(), -1, j);
  }
  for (var i = 0; i < a.length; ++i) {
    matrix.set((i + 1) * weights.deletion.toDouble(), i, -1);
  }
  var prevRowMinDistance = double.negativeInfinity;
  for (var i = 0; i < a.length; ++i) {
    var rowMinDistance = double.infinity;
    for (var j = 0; j <= b.length - 1; ++j) {
      final cost = a[i] == b[j] ? 0 : 1;
      final distances = [
        // deletion
        matrix.get(i - 1, j) + weights.deletion,
        // insertion
        matrix.get(i, j - 1) + weights.insertion,
        // substitution
        matrix.get(i - 1, j - 1) + cost * weights.substitution,
      ];
      if (j - 1 >= 0 &&
          i - 1 >= 0 &&
          j - 1 < b.length &&
          a[i] == b[j - 1] &&
          a[i - 1] == b[j]) {
        distances.add(matrix.get(i - 2, j - 2) + cost * weights.transposition);
      }
      final minDistance = distances.reduce(
        (value, element) => value < element ? value : element,
      );
      matrix.set(minDistance, i, j);
      if (minDistance < rowMinDistance) {
        rowMinDistance = minDistance;
      }
    }
    if (rowMinDistance > threshold) {
      if (prevRowMinDistance > threshold) {
        return double.infinity;
      }
      prevRowMinDistance = rowMinDistance;
    } else {
      prevRowMinDistance = double.negativeInfinity;
    }
  }
  final distance = matrix.get(a.length - 1, b.length - 1);
  if (distance > threshold) {
    return double.infinity;
  }
  return distance;
}

int _compareAlternatives(
  (String, double) a,
  (String, double) b,
  String target,
) {
  final cmp = a.$2.compareTo(b.$2);
  if (cmp != 0) {
    return cmp;
  }
  final aStartsWith = a.$1.startsWith(target);
  final bStartsWith = b.$1.startsWith(target);
  if (aStartsWith && !bStartsWith) {
    return -1;
  } else if (!aStartsWith && bStartsWith) {
    return 1;
  }
  return a.$1.compareTo(b.$1);
}

/// Mirror of `filterClosestAlternatives`: alternatives within the distance
/// threshold, restricted to the minimum distance, sorted for stable output.
List<String> filterClosestAlternatives(
  String target,
  List<String> alternatives,
  DistanceOptions options,
) {
  final validAlternatives = alternatives
      .map((alt) => (alt, damerauLevenshtein(target, alt, options)))
      .where((entry) => entry.$2 <= options.threshold)
      .toList();
  if (validAlternatives.isEmpty) {
    return [];
  }
  final minDistance = validAlternatives
      .map((entry) => entry.$2)
      .reduce((value, element) => value < element ? value : element);
  return (validAlternatives.where((entry) => entry.$2 == minDistance).toList()
        ..sort((a, b) => _compareAlternatives(a, b, target)))
      .map((entry) => entry.$1)
      .toList();
}

// ---------------------------------------------------------------------------
// Text formatting utilities (src/util/formatting.ts)
// ---------------------------------------------------------------------------

/// Mirror of `formatRowsWithColumns`: pads cells into aligned columns.
/// A column that is missing from any row is never padded (this mirrors the
/// JS `Math.max(len, undefined) → NaN → padEnd(NaN)` behavior).
List<String> formatRowsWithColumns(
  List<List<String>> cells, [
  List<String>? separators,
]) {
  if (cells.isEmpty) {
    return [];
  }
  final columnCount = cells
      .map((cellRow) => cellRow.length)
      .reduce((value, element) => value > element ? value : element);
  final maxLengths = List<int?>.filled(columnCount, 0);
  for (final cellRow in cells) {
    for (var i = 0; i < columnCount; i++) {
      if (i >= cellRow.length) {
        maxLengths[i] = null;
      } else {
        final current = maxLengths[i];
        if (current != null && cellRow[i].length > current) {
          maxLengths[i] = cellRow[i].length;
        }
      }
    }
  }
  String pad(String value, int columnIndex) {
    final width = maxLengths[columnIndex];
    return width == null ? value : value.padRight(width);
  }

  return cells.map((cellRow) {
    final parts = [pad(cellRow.isEmpty ? '' : cellRow[0], 0)];
    for (var i = 1; i < cellRow.length; i++) {
      parts.add(
        separators != null && i - 1 < separators.length
            ? separators[i - 1]
            : ' ',
      );
      parts.add(i == cellRow.length - 1 ? cellRow[i] : pad(cellRow[i], i));
    }
    return parts.join().trimRight();
  }).toList();
}

/// Mirror of `joinWithGrammar` for conjunctive lists.
String joinWithGrammar(
  List<String> parts, {
  required String conjunction,
  required bool serialComma,
}) {
  if (parts.length <= 1) {
    return parts.isEmpty ? '' : parts[0];
  }
  if (parts.length == 2) {
    return parts.join(' $conjunction ');
  }
  var allButLast = parts.sublist(0, parts.length - 1).join(', ');
  if (serialComma) {
    allButLast += ',';
  }
  return [allButLast, conjunction, parts[parts.length - 1]].join(' ');
}

// ---------------------------------------------------------------------------
// Scanner errors (src/parameter/scanner.ts)
// ---------------------------------------------------------------------------

/// Base class for all argument-scanner errors.
sealed class ArgumentScannerError implements Exception {
  ArgumentScannerError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Mirror of `formatMessageForArgumentScannerError`; the formatter map is
/// keyed by the error class name (matching TS `constructor.name`).
String formatMessageForArgumentScannerError(
  ArgumentScannerError error,
  Map<String, String Function(ArgumentScannerError error)> formatter,
) {
  final formatError = formatter[error.runtimeType.toString()];
  if (formatError != null) {
    return formatError(error);
  }
  return error.message;
}

/// `No flag registered for --…`.
final class FlagNotFoundError extends ArgumentScannerError {
  FlagNotFoundError(this.input, this.corrections, [this.aliasName])
    : super(_buildMessage(input, corrections, aliasName));

  final String input;
  final List<String> corrections;
  final String? aliasName;

  static String _buildMessage(
    String input,
    List<String> corrections,
    String? aliasName,
  ) {
    var message = 'No flag registered for --$input';
    if (aliasName != null) {
      message += ' (aliased from -$aliasName)';
    } else if (corrections.isNotEmpty) {
      final formattedCorrections = joinWithGrammar(
        corrections.map((correction) => '--$correction').toList(),
        conjunction: 'or',
        serialComma: true,
      );
      message += ', did you mean $formattedCorrections?';
    }
    return message;
  }
}

/// `No alias registered for -…`.
final class AliasNotFoundError extends ArgumentScannerError {
  AliasNotFoundError(this.input) : super('No alias registered for -$input');

  final String input;
}

/// `Failed to parse "…" for …: …`.
final class ArgumentParseError extends ArgumentScannerError {
  ArgumentParseError(
    this.externalFlagNameOrPlaceholder,
    this.input,
    this.exception,
  ) : super(
        'Failed to parse "$input" for $externalFlagNameOrPlaceholder: '
        '${_thrownMessage(exception)}',
      );

  final String externalFlagNameOrPlaceholder;
  final String input;
  final Object exception;
}

/// `Expected "…" to be one of (…)`.
final class EnumValidationError extends ArgumentScannerError {
  EnumValidationError(
    this.externalFlagName,
    this.input,
    this.values,
    List<String> corrections,
  ) : super(_buildMessage(input, values, corrections));

  final String externalFlagName;
  final String input;
  final List<String> values;

  static String _buildMessage(
    String input,
    List<String> values,
    List<String> corrections,
  ) {
    var message = 'Expected "$input" to be one of (${values.join('|')})';
    if (corrections.isNotEmpty) {
      final formattedCorrections = joinWithGrammar(
        corrections.map((str) => '"$str"').toList(),
        conjunction: 'or',
        serialComma: true,
      );
      message += ', did you mean $formattedCorrections?';
    }
    return message;
  }
}

/// `Expected input for flag --…`.
final class UnsatisfiedFlagError extends ArgumentScannerError {
  UnsatisfiedFlagError(this.externalFlagName, [this.nextFlagName])
    : super(
        'Expected input for flag --$externalFlagName'
        '${nextFlagName == null ? '' : ' but encountered --$nextFlagName instead'}',
      );

  final String externalFlagName;
  final String? nextFlagName;
}

/// `Too many arguments, expected … but encountered "…"`.
final class UnexpectedPositionalError extends ArgumentScannerError {
  UnexpectedPositionalError(this.expectedCount, this.input)
    : super(
        'Too many arguments, expected $expectedCount but encountered "$input"',
      );

  final int expectedCount;
  final String input;
}

/// `Expected argument for …` / `Expected at least … argument(s) for …`.
final class UnsatisfiedPositionalError extends ArgumentScannerError {
  UnsatisfiedPositionalError(this.placeholder, [this.limit])
    : super(_buildMessage(placeholder, limit));

  final String placeholder;

  /// `(minimum, found)` when a variadic minimum was not reached.
  final (int, int)? limit;

  static String _buildMessage(String placeholder, (int, int)? limit) {
    if (limit != null) {
      var message =
          'Expected at least ${limit.$1} argument(s) for $placeholder';
      if (limit.$2 == 0) {
        message += ' but found none';
      } else {
        message += ' but only found ${limit.$2}';
      }
      return message;
    }
    return 'Expected argument for $placeholder';
  }
}

/// `Cannot negate flag --… and pass "…" as value`.
final class InvalidNegatedFlagSyntaxError extends ArgumentScannerError {
  InvalidNegatedFlagSyntaxError(this.externalFlagName, this.valueText)
    : super(
        'Cannot negate flag --$externalFlagName and pass "$valueText" as value',
      );

  final String externalFlagName;
  final String valueText;
}

/// `Too many arguments for --…, encountered "…" after "…"`.
final class UnexpectedFlagError extends ArgumentScannerError {
  UnexpectedFlagError(this.externalFlagName, this.previousInput, this.input)
    : super(
        'Too many arguments for --$externalFlagName, encountered "$input" after "$previousInput"',
      );

  final String externalFlagName;
  final String previousInput;
  final String input;
}

/// Mirror of how TS reads `.message` from arbitrary thrown values in error
/// templates (`exception instanceof Error ? exception.message : String(...)`).
String _thrownMessage(Object exception) {
  if (exception is FormatException) {
    return exception.message;
  }
  if (exception is ArgumentScannerError) {
    return exception.message;
  }
  final text = exception.toString();
  const prefixes = ['Exception: ', 'Bad state: ', 'Invalid argument(s): '];
  for (final prefix in prefixes) {
    if (text.startsWith(prefix)) {
      return text.substring(prefix.length);
    }
  }
  return text;
}

// ---------------------------------------------------------------------------
// Flag helpers
// ---------------------------------------------------------------------------

final class _NamedFlag {
  const _NamedFlag(this.name, this.flag);

  final String name;
  final Flag flag;
}

final class _FlagMatch {
  const _FlagMatch(this.namedFlag, {this.negated = false});

  final _NamedFlag namedFlag;
  final bool negated;
}

Object? _flagDefault(Flag flag) {
  return switch (flag) {
    BooleanFlag f => f.defaultValue,
    EnumFlag f => f.defaultValue,
    ParsedFlag f => f.defaultValue,
    CounterFlag() => null,
  };
}

/// Mirror of `hasDefault`.
bool _hasDefault(Flag flag) => _flagDefault(flag) != null;

/// Mirror of `isOptionalAtRuntime` (`flag.optional ?? hasDefault(flag)`).
bool _isOptionalAtRuntime(Flag flag) => flag.optional ?? _hasDefault(flag);

/// Mirror of `isVariadicFlag`.
bool _isVariadicFlag(Flag flag) {
  return switch (flag) {
    CounterFlag() => true,
    EnumFlag f => f.variadic || f.variadicSeparator != null,
    ParsedFlag f => f.variadic || f.variadicSeparator != null,
    BooleanFlag() => false,
  };
}

/// The TS `variadic: string` separator form, when configured.
String? _variadicSeparator(Flag flag) {
  return switch (flag) {
    EnumFlag f => f.variadicSeparator,
    ParsedFlag f => f.variadicSeparator,
    _ => null,
  };
}

/// Mirror of `getPlaceholder`.
String _getPlaceholder(PositionalParameter param, int? index) {
  final placeholder = param.placeholder;
  if (placeholder != null) {
    return placeholder;
  }
  return index != null ? 'arg$index' : 'args';
}

/// Mirror of `asExternal`.
String _asExternal(String internal, ScannerCaseStyle scannerCaseStyle) {
  return scannerCaseStyle == ScannerCaseStyle.allowKebabForCamel
      ? convertCamelCaseToKebabCase(internal)
      : internal;
}

/// Mirror of `parseInput` (wraps parse failures in [ArgumentParseError]).
Future<Object?> _parseInput(
  String externalFlagNameOrPlaceholder,
  FlagParseFunction parse,
  String input,
) async {
  try {
    return await parse(input);
  } catch (exc) {
    throw ArgumentParseError(externalFlagNameOrPlaceholder, input, exc);
  }
}

/// Mirror of `undoNegation` (including the verbatim `slice(4)` for names that
/// already contain a dash; the camelCase path is the one dotweave reaches).
String? _undoNegation(String flagName) {
  if (flagName.startsWith('no') && flagName.length > 2) {
    if (flagName[2] == '-') {
      return flagName.length >= 4 ? flagName.substring(4) : '';
    }
    final firstChar = flagName[2];
    final firstUpper = firstChar.toUpperCase();
    if (firstChar != firstUpper) {
      return null;
    }
    final firstLower = firstChar.toLowerCase();
    return firstLower + flagName.substring(3);
  }
  return null;
}

/// Mirror of `resolveAliases`.
Map<String, _NamedFlag> _resolveAliases(
  Map<String, Flag> flags,
  Map<String, String> aliases,
  ScannerCaseStyle scannerCaseStyle,
) {
  final resolved = <String, _NamedFlag>{};
  for (final entry in aliases.entries) {
    final internalFlagName = entry.value;
    final flag = flags[internalFlagName];
    if (flag == null) {
      final externalFlagName = _asExternal(internalFlagName, scannerCaseStyle);
      throw FlagNotFoundError(externalFlagName, const [], entry.key);
    }
    resolved[entry.key] = _NamedFlag(internalFlagName, flag);
  }
  return resolved;
}

/// Mirror of `findInternalFlagMatch` (dist index.js:474).
_FlagMatch _findInternalFlagMatch(
  String externalFlagName,
  Map<String, Flag> flags,
  ScannerConfig config,
) {
  final internalFlagName = externalFlagName;
  var flag = flags[internalFlagName];
  String? foundFlagWithNegatedFalse;
  var foundFlagWithNegatedFalseFromKebabConversion = false;
  if (flag == null) {
    final internalWithoutNegation = _undoNegation(internalFlagName);
    if (internalWithoutNegation != null) {
      flag = flags[internalWithoutNegation];
      if (flag is BooleanFlag) {
        if (flag.withNegated != false) {
          return _FlagMatch(
            _NamedFlag(internalWithoutNegation, flag),
            negated: true,
          );
        } else {
          foundFlagWithNegatedFalse = internalWithoutNegation;
          flag = null;
        }
      }
    }
  }
  final camelCaseFlagName = convertKebabCaseToCamelCase(externalFlagName);
  if (config.caseStyle == ScannerCaseStyle.allowKebabForCamel && flag == null) {
    flag = flags[camelCaseFlagName];
    if (flag != null) {
      return _FlagMatch(_NamedFlag(camelCaseFlagName, flag));
    }
    final camelCaseWithoutNegation = _undoNegation(camelCaseFlagName);
    if (camelCaseWithoutNegation != null) {
      flag = flags[camelCaseWithoutNegation];
      if (flag is BooleanFlag) {
        if (flag.withNegated != false) {
          return _FlagMatch(
            _NamedFlag(camelCaseWithoutNegation, flag),
            negated: true,
          );
        } else {
          foundFlagWithNegatedFalse = camelCaseWithoutNegation;
          foundFlagWithNegatedFalseFromKebabConversion = true;
          flag = null;
        }
      }
    }
  }
  if (flag == null) {
    if (foundFlagWithNegatedFalse != null) {
      var correction = foundFlagWithNegatedFalse;
      if (foundFlagWithNegatedFalseFromKebabConversion &&
          externalFlagName.contains('-')) {
        correction = convertCamelCaseToKebabCase(foundFlagWithNegatedFalse);
      }
      throw FlagNotFoundError(externalFlagName, [correction]);
    }
    if (flags.containsKey(camelCaseFlagName)) {
      throw FlagNotFoundError(externalFlagName, [camelCaseFlagName]);
    }
    final kebabCaseFlagName = convertCamelCaseToKebabCase(externalFlagName);
    if (flags.containsKey(kebabCaseFlagName)) {
      throw FlagNotFoundError(externalFlagName, [kebabCaseFlagName]);
    }
    final corrections = filterClosestAlternatives(
      internalFlagName,
      flags.keys.toList(),
      config.distanceOptions,
    );
    throw FlagNotFoundError(externalFlagName, corrections);
  }
  return _FlagMatch(_NamedFlag(internalFlagName, flag));
}

/// Mirror of `isNiladic`.
bool _isNiladic(_FlagMatch match) {
  final flag = match.namedFlag.flag;
  return flag is BooleanFlag || flag is CounterFlag;
}

final RegExp _flagShorthandPattern = RegExp(
  r'^-([a-z]+)$',
  caseSensitive: false,
);
final RegExp _flagNamePattern = RegExp(
  r'^--([a-z][a-z-.\d_]+)$',
  caseSensitive: false,
);
final RegExp _flagNameValuePattern = RegExp(
  r'^--([a-z][a-z-.\d_]+)=(.+)$',
  caseSensitive: false,
);
final RegExp _aliasValuePattern = RegExp(
  r'^-([a-z])=(.+)$',
  caseSensitive: false,
);

/// Mirror of `findFlagsByArgument`.
List<_FlagMatch> _findFlagsByArgument(
  String arg,
  Map<String, Flag> flags,
  Map<String, _NamedFlag> resolvedAliases,
  ScannerConfig config,
) {
  final shorthandMatch = _flagShorthandPattern.firstMatch(arg);
  if (shorthandMatch != null) {
    final batch = shorthandMatch.group(1)!;
    return batch.split('').map((alias) {
      final namedFlag = resolvedAliases[alias];
      if (namedFlag == null) {
        throw AliasNotFoundError(alias);
      }
      return _FlagMatch(namedFlag);
    }).toList();
  }
  final flagNameMatch = _flagNamePattern.firstMatch(arg);
  if (flagNameMatch != null) {
    final externalFlagName = flagNameMatch.group(1)!;
    return [_findInternalFlagMatch(externalFlagName, flags, config)];
  }
  return [];
}

/// Mirror of `findFlagByArgumentWithInput` (`--flag=value` / `-a=value`).
(_NamedFlag, String)? _findFlagByArgumentWithInput(
  String arg,
  Map<String, Flag> flags,
  Map<String, _NamedFlag> resolvedAliases,
  ScannerConfig config,
) {
  final flagsNameMatch = _flagNameValuePattern.firstMatch(arg);
  if (flagsNameMatch != null) {
    final externalFlagName = flagsNameMatch.group(1)!;
    final match = _findInternalFlagMatch(externalFlagName, flags, config);
    final valueText = flagsNameMatch.group(2)!;
    if (match.negated) {
      throw InvalidNegatedFlagSyntaxError(externalFlagName, valueText);
    }
    return (match.namedFlag, valueText);
  }
  final aliasValueMatch = _aliasValuePattern.firstMatch(arg);
  if (aliasValueMatch != null) {
    final aliasName = aliasValueMatch.group(1)!;
    final namedFlag = resolvedAliases[aliasName];
    if (namedFlag == null) {
      throw AliasNotFoundError(aliasName);
    }
    final valueText = aliasValueMatch.group(2)!;
    return (namedFlag, valueText);
  }
  return null;
}

/// Mirror of `parseInputsForFlag` (dist index.js:600).
Future<Object?> _parseInputsForFlag(
  String externalFlagName,
  Flag flag,
  List<String>? inputs,
  ScannerConfig config,
) async {
  if (inputs == null) {
    if (_hasDefault(flag)) {
      switch (flag) {
        case BooleanFlag f:
          return f.defaultValue;
        case EnumFlag f:
          final defaultValue = f.defaultValue;
          if (_isVariadicFlag(f) && defaultValue is List<String>) {
            for (final value in defaultValue) {
              if (!f.values.contains(value)) {
                final corrections = filterClosestAlternatives(
                  value,
                  f.values,
                  config.distanceOptions,
                );
                throw EnumValidationError(
                  externalFlagName,
                  value,
                  f.values,
                  corrections,
                );
              }
            }
            return defaultValue;
          }
          return defaultValue;
        case ParsedFlag f:
          final defaultValue = f.defaultValue;
          if (_isVariadicFlag(f) && defaultValue is List<String>) {
            return [
              for (final input in defaultValue)
                await _parseInput(externalFlagName, f.parse, input),
            ];
          }
          return _parseInput(externalFlagName, f.parse, defaultValue as String);
        case CounterFlag():
          break;
      }
    }
    if (flag.optional ?? false) {
      return null;
    }
    if (flag is BooleanFlag) {
      return false;
    } else if (flag is CounterFlag) {
      return 0;
    }
    throw UnsatisfiedFlagError(externalFlagName);
  }
  if (flag is CounterFlag) {
    var total = 0;
    for (final input in inputs) {
      try {
        total += numberParser(input).toInt();
      } catch (exc) {
        throw ArgumentParseError(externalFlagName, input, exc);
      }
    }
    return total;
  }
  if (_isVariadicFlag(flag)) {
    if (flag is EnumFlag) {
      for (final input in inputs) {
        if (!flag.values.contains(input)) {
          final corrections = filterClosestAlternatives(
            input,
            flag.values,
            config.distanceOptions,
          );
          throw EnumValidationError(
            externalFlagName,
            input,
            flag.values,
            corrections,
          );
        }
      }
      return inputs;
    }
    final parsed = flag as ParsedFlag;
    return [
      for (final input in inputs)
        await _parseInput(externalFlagName, parsed.parse, input),
    ];
  }
  final input = inputs[0];
  if (flag is BooleanFlag) {
    try {
      return looseBooleanParser(input);
    } catch (exc) {
      throw ArgumentParseError(externalFlagName, input, exc);
    }
  }
  if (flag is EnumFlag) {
    if (!flag.values.contains(input)) {
      final corrections = filterClosestAlternatives(
        input,
        flag.values,
        config.distanceOptions,
      );
      throw EnumValidationError(
        externalFlagName,
        input,
        flag.values,
        corrections,
      );
    }
    return input;
  }
  return _parseInput(externalFlagName, (flag as ParsedFlag).parse, input);
}

/// Mirror of `storeInput`.
void _storeInput(
  Map<String, List<String>> flagInputs,
  ScannerCaseStyle scannerCaseStyle,
  _NamedFlag namedFlag,
  String input,
) {
  final inputs = flagInputs[namedFlag.name] ?? const [];
  if (inputs.isNotEmpty && !_isVariadicFlag(namedFlag.flag)) {
    final externalFlagName = _asExternal(namedFlag.name, scannerCaseStyle);
    throw UnexpectedFlagError(externalFlagName, inputs[0], input);
  }
  final separator = _variadicSeparator(namedFlag.flag);
  if (separator != null) {
    final multipleInputs = input.split(separator);
    flagInputs[namedFlag.name] = [...inputs, ...multipleInputs];
  } else {
    flagInputs[namedFlag.name] = [...inputs, input];
  }
}

// ---------------------------------------------------------------------------
// Argument scanner (src/parameter/scanner.ts `buildArgumentScanner`)
// ---------------------------------------------------------------------------

sealed class _ScanOutcome {
  const _ScanOutcome();
}

final class _ScanSuccess extends _ScanOutcome {
  const _ScanSuccess(this.flags, this.positional);

  final Map<String, Object?> flags;
  final List<Object?> positional;
}

final class _ScanFailure extends _ScanOutcome {
  const _ScanFailure(this.errors);

  final List<Object> errors;
}

final class _ArgumentScanner {
  _ArgumentScanner(CommandParameters parameters, this.config)
    : flags = parameters.flags,
      aliases = parameters.aliases,
      positional =
          parameters.positional ?? const TuplePositionalParameters([]) {
    resolvedAliases = _resolveAliases(flags, aliases, config.caseStyle);
  }

  final ScannerConfig config;
  final Map<String, Flag> flags;
  final Map<String, String> aliases;
  final PositionalParameters positional;
  late final Map<String, _NamedFlag> resolvedAliases;

  final List<String> _positionalInputs = [];
  final Map<String, List<String>> _flagInputs = {};
  int _positionalIndex = 0;
  _NamedFlag? _activeFlag;
  bool _treatInputsAsArguments = false;

  bool _isFlagSatisfiedByInputs(String key) {
    final inputs = _flagInputs[key];
    if (inputs != null) {
      final flag = flags[key]!;
      if (_isVariadicFlag(flag)) {
        return false;
      }
      return true;
    }
    return false;
  }

  /// Flushes an active `inferEmpty` parsed flag with an empty input; returns
  /// false when the active flag cannot be inferred (caller must throw).
  bool _flushActiveFlagWithEmpty() {
    final active = _activeFlag;
    if (active != null &&
        active.flag is ParsedFlag &&
        (active.flag as ParsedFlag).inferEmpty) {
      _storeInput(_flagInputs, config.caseStyle, active, '');
      _activeFlag = null;
      return true;
    }
    return false;
  }

  void next(String input) {
    if (!_treatInputsAsArguments &&
        config.allowArgumentEscapeSequence &&
        input == '--') {
      final active = _activeFlag;
      if (active != null && !_flushActiveFlagWithEmpty()) {
        final externalFlagName = _asExternal(active.name, config.caseStyle);
        throw UnsatisfiedFlagError(externalFlagName);
      }
      _treatInputsAsArguments = true;
      return;
    }
    if (!_treatInputsAsArguments) {
      final flagInput = _findFlagByArgumentWithInput(
        input,
        flags,
        resolvedAliases,
        config,
      );
      if (flagInput != null) {
        final active = _activeFlag;
        if (active != null && !_flushActiveFlagWithEmpty()) {
          final externalFlagName = _asExternal(active.name, config.caseStyle);
          final nextExternalFlagName = _asExternal(
            flagInput.$1.name,
            config.caseStyle,
          );
          throw UnsatisfiedFlagError(externalFlagName, nextExternalFlagName);
        }
        _storeInput(_flagInputs, config.caseStyle, flagInput.$1, flagInput.$2);
        return;
      }
      final nextFlags = _findFlagsByArgument(
        input,
        flags,
        resolvedAliases,
        config,
      );
      if (nextFlags.isNotEmpty) {
        final active = _activeFlag;
        if (active != null && !_flushActiveFlagWithEmpty()) {
          final externalFlagName = _asExternal(active.name, config.caseStyle);
          final nextFlagName = _asExternal(
            nextFlags[0].namedFlag.name,
            config.caseStyle,
          );
          throw UnsatisfiedFlagError(externalFlagName, nextFlagName);
        }
        if (nextFlags.every(_isNiladic)) {
          for (final nextFlag in nextFlags) {
            if (nextFlag.namedFlag.flag is BooleanFlag) {
              _storeInput(
                _flagInputs,
                config.caseStyle,
                nextFlag.namedFlag,
                nextFlag.negated ? 'false' : 'true',
              );
            } else {
              _storeInput(
                _flagInputs,
                config.caseStyle,
                nextFlag.namedFlag,
                '1',
              );
            }
          }
        } else if (nextFlags.length > 1) {
          final nextFlagExpectingArg = nextFlags.firstWhere(
            (nextFlag) => !_isNiladic(nextFlag),
          );
          final externalFlagName = _asExternal(
            nextFlagExpectingArg.namedFlag.name,
            config.caseStyle,
          );
          throw UnsatisfiedFlagError(externalFlagName);
        } else {
          _activeFlag = nextFlags[0].namedFlag;
        }
        return;
      }
    }
    final active = _activeFlag;
    if (active != null) {
      _storeInput(_flagInputs, config.caseStyle, active, input);
      _activeFlag = null;
    } else {
      final pos = positional;
      if (pos is TuplePositionalParameters) {
        if (_positionalIndex >= pos.parameters.length) {
          throw UnexpectedPositionalError(pos.parameters.length, input);
        }
      } else if (pos is ArrayPositionalParameters) {
        final maximum = pos.maximum;
        if (maximum != null && _positionalIndex >= maximum) {
          throw UnexpectedPositionalError(maximum, input);
        }
      }
      _positionalInputs.add(input);
      ++_positionalIndex;
    }
  }

  Future<_ScanOutcome> parseArguments(RunContext context) async {
    final errors = <Object>[];
    final positionalValues = <Object?>[];
    final positionalErrors = <Object>[];
    final pos = positional;
    if (pos is ArrayPositionalParameters) {
      final minimum = pos.minimum;
      if (minimum != null && _positionalIndex < minimum) {
        errors.add(
          UnsatisfiedPositionalError(_getPlaceholder(pos.parameter, null), (
            minimum,
            _positionalIndex,
          )),
        );
      }
      for (var i = 0; i < _positionalInputs.length; i++) {
        final placeholder = _getPlaceholder(pos.parameter, i + 1);
        try {
          positionalValues.add(
            await _parseInput(
              placeholder,
              pos.parameter.parse,
              _positionalInputs[i],
            ),
          );
        } catch (exc) {
          positionalErrors.add(exc);
        }
      }
    } else {
      final parameters = (pos as TuplePositionalParameters).parameters;
      for (var i = 0; i < parameters.length; i++) {
        final param = parameters[i];
        final placeholder = _getPlaceholder(param, i + 1);
        final input = i < _positionalInputs.length
            ? _positionalInputs[i]
            : null;
        try {
          if (input == null) {
            final defaultValue = param.defaultValue;
            if (defaultValue != null) {
              positionalValues.add(
                await _parseInput(placeholder, param.parse, defaultValue),
              );
            } else if (param.optional ?? false) {
              positionalValues.add(null);
            } else {
              throw UnsatisfiedPositionalError(placeholder);
            }
          } else {
            positionalValues.add(
              await _parseInput(placeholder, param.parse, input),
            );
          }
        } catch (exc) {
          positionalErrors.add(exc);
        }
      }
    }
    _flushActiveFlagWithEmpty();
    final flagErrors = <Object>[];
    final flagEntries = <String, Object?>{};
    for (final entry in flags.entries) {
      final externalFlagName = _asExternal(entry.key, config.caseStyle);
      try {
        final active = _activeFlag;
        if (active != null && active.name == entry.key) {
          throw UnsatisfiedFlagError(externalFlagName);
        }
        flagEntries[entry.key] = await _parseInputsForFlag(
          externalFlagName,
          entry.value,
          _flagInputs[entry.key],
          config,
        );
      } catch (exc) {
        flagErrors.add(exc);
      }
    }
    errors.addAll(positionalErrors);
    errors.addAll(flagErrors);
    if (errors.isNotEmpty) {
      return _ScanFailure(errors);
    }
    return _ScanSuccess(flagEntries, positionalValues);
  }

  /// Mirror of the scanner's `proposeCompletions` (dist index.js:892).
  Future<List<InputCompletion>> proposeCompletions({
    required String partial,
    required CompletionConfig completionConfig,
    required ApplicationText text,
    required RunContext context,
    required bool includeVersionFlag,
  }) async {
    final active = _activeFlag;
    if (active != null) {
      return _proposeFlagCompletionsForPartialInput(active.flag, partial);
    }
    final completions = <InputCompletion>[];
    if (!_treatInputsAsArguments) {
      final shorthandMatch = _flagShorthandPattern.firstMatch(partial);
      if (completionConfig.includeAliases) {
        if (partial == '' || partial == '-') {
          final incompleteAliases = aliases.entries.where(
            (entry) => !_isFlagSatisfiedByInputs(entry.value),
          );
          for (final entry in incompleteAliases) {
            final flag = resolvedAliases[entry.key];
            if (flag != null) {
              completions.add(
                InputCompletion(
                  kind: 'argument:flag',
                  completion: '-${entry.key}',
                  brief: flag.flag.brief,
                ),
              );
            }
          }
        } else if (shorthandMatch != null) {
          final partialAliases = shorthandMatch.group(1)!.split('');
          if (partialAliases.contains('h')) {
            return [];
          }
          if (includeVersionFlag && partialAliases.contains('v')) {
            return [];
          }
          final flagInputsIncludingPartial = <String, List<String>>{
            for (final entry in _flagInputs.entries) entry.key: entry.value,
          };
          for (final alias in partialAliases) {
            final namedFlag = resolvedAliases[alias];
            if (namedFlag == null) {
              throw AliasNotFoundError(alias);
            }
            _storeInput(
              flagInputsIncludingPartial,
              config.caseStyle,
              namedFlag,
              namedFlag.flag is BooleanFlag ? 'true' : '1',
            );
          }
          final lastAlias = partialAliases.isEmpty ? null : partialAliases.last;
          if (lastAlias != null) {
            final namedFlag = resolvedAliases[lastAlias];
            if (namedFlag != null) {
              completions.add(
                InputCompletion(
                  kind: 'argument:flag',
                  completion: partial,
                  brief: namedFlag.flag.brief,
                ),
              );
            }
          }
          bool satisfiedIncludingPartial(String key) {
            final inputs = flagInputsIncludingPartial[key];
            if (inputs != null) {
              return !_isVariadicFlag(flags[key]!);
            }
            return false;
          }

          final incompleteAliases = aliases.entries.where(
            (entry) => !satisfiedIncludingPartial(entry.value),
          );
          for (final entry in incompleteAliases) {
            final flag = resolvedAliases[entry.key];
            if (flag != null) {
              completions.add(
                InputCompletion(
                  kind: 'argument:flag',
                  completion: '$partial${entry.key}',
                  brief: flag.flag.brief,
                ),
              );
            }
          }
        }
      }
      if (partial == '' || partial == '-' || partial.startsWith('--')) {
        if (config.allowArgumentEscapeSequence) {
          completions.add(
            InputCompletion(
              kind: 'argument:flag',
              completion: '--',
              brief: text.briefs.argumentEscapeSequence,
            ),
          );
        }
        var incompleteFlags = flags.entries
            .where((entry) => !_isFlagSatisfiedByInputs(entry.key))
            .map((entry) => (entry.key, entry.value))
            .toList();
        if (config.caseStyle == ScannerCaseStyle.allowKebabForCamel) {
          incompleteFlags = incompleteFlags
              .map((entry) => (convertCamelCaseToKebabCase(entry.$1), entry.$2))
              .toList();
        }
        final possibleFlags = incompleteFlags
            .map((entry) => ('--${entry.$1}', entry.$2))
            .where((entry) => entry.$1.startsWith(partial));
        completions.addAll(
          possibleFlags.map(
            (entry) => InputCompletion(
              kind: 'argument:flag',
              completion: entry.$1,
              brief: entry.$2.brief,
            ),
          ),
        );
      }
    }
    final pos = positional;
    if (pos is ArrayPositionalParameters) {
      final propose = pos.parameter.proposeCompletions;
      if (propose != null) {
        final maximum = pos.maximum;
        if (maximum == null || _positionalIndex < maximum) {
          final positionalCompletions = await propose(partial);
          completions.addAll(
            positionalCompletions.map(
              (value) => InputCompletion(
                kind: 'argument:value',
                completion: value,
                brief: pos.parameter.brief,
              ),
            ),
          );
        }
      }
    } else {
      final parameters = (pos as TuplePositionalParameters).parameters;
      final nextPositional = _positionalIndex < parameters.length
          ? parameters[_positionalIndex]
          : null;
      final propose = nextPositional?.proposeCompletions;
      if (nextPositional != null && propose != null) {
        final positionalCompletions = await propose(partial);
        completions.addAll(
          positionalCompletions.map(
            (value) => InputCompletion(
              kind: 'argument:value',
              completion: value,
              brief: nextPositional.brief,
            ),
          ),
        );
      }
    }
    return completions
        .where((completion) => completion.completion.startsWith(partial))
        .toList();
  }
}

/// Mirror of `proposeFlagCompletionsForPartialInput`.
Future<List<InputCompletion>> _proposeFlagCompletionsForPartialInput(
  Flag flag,
  String partial,
) async {
  final separator = _variadicSeparator(flag);
  if (separator != null && partial.endsWith(separator)) {
    return _proposeFlagCompletionsForPartialInput(flag, '');
  }
  List<String> values;
  if (flag is EnumFlag) {
    values = flag.values;
  } else if (flag is ParsedFlag && flag.proposeCompletions != null) {
    values = await flag.proposeCompletions!(partial);
  } else {
    values = [];
  }
  return values
      .map(
        (value) => InputCompletion(
          kind: 'argument:value',
          completion: value,
          brief: flag.brief,
        ),
      )
      .where((completion) => completion.completion.startsWith(partial))
      .toList();
}

// ---------------------------------------------------------------------------
// Builder validation (src/routing/command/builder.ts)
// ---------------------------------------------------------------------------

Iterable<String> _asNegationFlagNames(String flagName) sync* {
  yield 'no-${convertCamelCaseToKebabCase(flagName)}';
  yield 'no${flagName[0].toUpperCase()}${flagName.substring(1)}';
}

/// Mirror of `checkForNegationCollisions`.
void _checkForNegationCollisions(Map<String, Flag> flags) {
  final flagsAllowingNegation = flags.entries.where(
    (entry) => entry.value is BooleanFlag && !(entry.value.optional ?? false),
  );
  for (final entry in flagsAllowingNegation) {
    for (final negatedFlagName in _asNegationFlagNames(entry.key)) {
      if (flags.containsKey(negatedFlagName)) {
        throw RouterInternalError(
          'Unable to allow negation for --${entry.key} as it conflicts with --$negatedFlagName',
        );
      }
    }
  }
}

/// Mirror of `checkForInvalidVariadicSeparators`.
void _checkForInvalidVariadicSeparators(Map<String, Flag> flags) {
  for (final entry in flags.entries) {
    final separator = _variadicSeparator(entry.value);
    if (separator != null) {
      if (separator.isEmpty) {
        throw RouterInternalError(
          'Unable to use "" as variadic separator for --${entry.key} as it is empty',
        );
      }
      if (RegExp(r'\s').hasMatch(separator)) {
        throw RouterInternalError(
          'Unable to use "$separator" as variadic separator for --${entry.key} as it contains whitespace',
        );
      }
    }
  }
}
