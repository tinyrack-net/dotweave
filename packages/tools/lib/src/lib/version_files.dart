import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'error.dart';

/// Reads [filePath], reporting a missing file as a [ToolException] rather than
/// letting a raw [FileSystemException] escape.
Future<String> _readVersionFile(String filePath) async {
  final file = File(filePath);

  if (!await file.exists()) {
    throw ToolException('Version file not found: $filePath');
  }

  return file.readAsString();
}

/// Reads the `version` field from a pubspec.yaml file.
Future<String> readPubspecVersion(String filePath) async {
  final content = await _readVersionFile(filePath);
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
  final content = await _readVersionFile(filePath);
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
