import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'error.dart';

/// Reads [filePath], reporting a missing file as a [ShipworldException] rather than
/// letting a raw [FileSystemException] escape.
Future<String> _readVersionFile(String filePath) async {
  final file = File(filePath);

  if (!await file.exists()) {
    throw ShipworldException('Version file not found: $filePath');
  }

  return file.readAsString();
}

/// Reads the `version` field from a pubspec.yaml file.
Future<String> readPubspecVersion(String filePath) async {
  final content = await _readVersionFile(filePath);
  final Object? parsed = loadYaml(content);

  if (parsed is! YamlMap) {
    throw ShipworldException('Invalid pubspec.yaml at $filePath');
  }

  final Object? version = parsed['version'];

  if (version is! String) {
    throw ShipworldException('Missing version in $filePath');
  }

  return version;
}

/// Writes the `version` field to a pubspec.yaml file, preserving all other
/// content (including comments and formatting).
Future<void> writePubspecVersion(String filePath, String version) async {
  final file = File(filePath);
  await file.writeAsString(
    renderPubspecVersion(await file.readAsString(), version),
  );
}

/// Renders a pubspec with its version updated while preserving other content.
String renderPubspecVersion(String content, String version) {
  final editor = YamlEditor(content)..update(['version'], version);
  return editor.toString();
}

/// Renders the generated `version.g.dart` contents for [version].
String renderVersionConstant(
  String version, {
  String constant = 'packageVersion',
}) {
  return '// Generated from pubspec.yaml by the release tool. '
      'Do not edit by hand.\n'
      "const String $constant = '$version';\n";
}

/// Reads the `packageVersion` constant from a generated `version.g.dart`.
Future<String> readVersionConstant(
  String filePath, {
  String constant = 'packageVersion',
}) async {
  final content = await _readVersionFile(filePath);
  final pattern = RegExp(
    "const String ${RegExp.escape(constant)} = '([^']+)';",
  );
  final match = pattern.firstMatch(content);

  if (match == null) {
    throw ShipworldException('Missing $constant constant in $filePath');
  }

  return match.group(1)!;
}

/// Regenerates a `version.g.dart` file for [version].
Future<void> writeVersionConstant(
  String filePath,
  String version, {
  String constant = 'packageVersion',
}) async {
  await File(
    filePath,
  ).writeAsString(renderVersionConstant(version, constant: constant));
}
