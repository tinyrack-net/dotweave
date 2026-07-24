import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'error.dart';

/// Reads the `version` field from a package.json file.
Future<String> readPackageJsonVersion(String filePath) async {
  final packageJson = await _readPackageJson(filePath);
  final version = packageJson['version'];

  if (version is! String) {
    throw ToolException('Missing version in $filePath');
  }

  return version;
}

/// Writes the `version` field to a package.json file, preserving the other
/// fields, 2-space indentation, and the trailing newline.
Future<void> writePackageJsonVersion(String filePath, String version) async {
  final packageJson = await _readPackageJson(filePath);

  packageJson['version'] = version;

  const encoder = JsonEncoder.withIndent('  ');

  await File(filePath).writeAsString('${encoder.convert(packageJson)}\n');
}

Future<Map<String, Object?>> _readPackageJson(String filePath) async {
  final content = await File(filePath).readAsString();
  final Object? parsed = jsonDecode(content);

  if (parsed is! Map<String, Object?>) {
    throw ToolException('Invalid package.json at $filePath');
  }

  return parsed;
}

/// Reads the `version` field from a pubspec.yaml file.
Future<String> readPubspecVersion(String filePath) async {
  final content = await File(filePath).readAsString();
  final Object? parsed = loadYaml(content);

  if (parsed is! YamlMap) {
    throw ToolException('Invalid pubspec.yaml at $filePath');
  }

  final Object? version = parsed['version'];

  if (version is! String) {
    throw ToolException('Missing version in $filePath');
  }

  return version;
}

/// Writes the `version` field to a pubspec.yaml file, preserving all other
/// content (including comments and formatting).
Future<void> writePubspecVersion(String filePath, String version) async {
  final file = File(filePath);
  final editor = YamlEditor(await file.readAsString());

  editor.update(['version'], version);

  await file.writeAsString(editor.toString());
}

final RegExp _versionConstantPattern = RegExp(
  r"const String packageVersion = '([^']+)';",
);

/// Renders the generated `version.g.dart` contents for [version].
String renderVersionConstant(String version) {
  return '// Generated from pubspec.yaml by the release tool. '
      'Do not edit by hand.\n'
      "const String packageVersion = '$version';\n";
}

/// Reads the `packageVersion` constant from a generated `version.g.dart`.
Future<String> readVersionConstant(String filePath) async {
  final content = await File(filePath).readAsString();
  final match = _versionConstantPattern.firstMatch(content);

  if (match == null) {
    throw ToolException('Missing packageVersion constant in $filePath');
  }

  return match.group(1)!;
}

/// Regenerates a `version.g.dart` file for [version].
Future<void> writeVersionConstant(String filePath, String version) async {
  await File(filePath).writeAsString(renderVersionConstant(version));
}
