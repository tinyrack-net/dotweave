import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'error.dart';

/// Supported release target kinds.
enum ShipworldTargetKind {
  pubPackage('pub-package'),
  cliApplication('cli-application'),
  flutterApplication('flutter-application');

  const ShipworldTargetKind(this.yamlName);

  /// Name used in `shipworld.yaml`.
  final String yamlName;

  static ShipworldTargetKind parse(String value) {
    return values.firstWhere(
      (kind) => kind.yamlName == value,
      orElse: () => throw ShipworldException(
        'Unknown shipworld target kind: $value',
        code: 'invalid_config',
      ),
    );
  }
}

/// Supported synchronized version-file writers.
enum VersionWriterKind {
  dartConstant('dart-constant');

  const VersionWriterKind(this.yamlName);

  final String yamlName;

  static VersionWriterKind parse(String value) {
    return values.firstWhere(
      (kind) => kind.yamlName == value,
      orElse: () => throw ShipworldException(
        'Unknown synchronized version writer: $value',
        code: 'invalid_config',
      ),
    );
  }
}

/// A generated file that must carry the target version.
final class SynchronizedVersionConfig {
  const SynchronizedVersionConfig({
    required this.kind,
    required this.path,
    this.constant = 'packageVersion',
  });

  final VersionWriterKind kind;
  final String path;
  final String constant;
}

/// Version source and synchronized writer configuration.
final class VersionConfig {
  const VersionConfig({
    required this.pubspecPath,
    this.synchronized = const [],
  });

  final String pubspecPath;
  final List<SynchronizedVersionConfig> synchronized;
}

/// Product metadata shared by desktop package generators.
final class ProductConfig {
  const ProductConfig({
    required this.name,
    required this.displayName,
    required this.description,
    required this.executable,
    this.homepage,
    this.repository,
  });

  final String name;
  final String displayName;
  final String description;
  final String executable;
  final String? homepage;
  final String? repository;
}

/// Configured prebuilt payload shape.
enum PayloadKind {
  executable,
  directory;

  static PayloadKind parse(String value) {
    return values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => throw ShipworldException(
        'Unknown payload kind: $value',
        code: 'invalid_config',
      ),
    );
  }
}

/// Target-level payload metadata.
final class PayloadConfig {
  const PayloadConfig({required this.kind, required this.launcher});

  final PayloadKind kind;
  final String launcher;
}

/// Names of environment variables containing the MSIX identity.
final class WindowsIdentityEnvironmentConfig {
  const WindowsIdentityEnvironmentConfig({
    required this.name,
    required this.publisher,
    required this.publisherDisplayName,
    this.displayName,
  });

  final String name;
  final String publisher;
  final String publisherDisplayName;
  final String? displayName;
}

/// Windows package metadata for a target.
final class WindowsTargetConfig {
  const WindowsTargetConfig({
    required this.applicationId,
    required this.executable,
    required this.identityEnvironment,
    this.backgroundColor = 'transparent',
  });

  final String applicationId;
  final String executable;
  final String backgroundColor;
  final WindowsIdentityEnvironmentConfig identityEnvironment;
}

/// macOS package metadata for a target.
final class MacosTargetConfig {
  const MacosTargetConfig({this.entitlements});

  final String? entitlements;
}

/// Linux AppImage metadata for a target.
final class LinuxTargetConfig {
  const LinuxTargetConfig({
    required this.icon,
    required this.categories,
    required this.terminal,
  });

  final String icon;
  final List<String> categories;
  final bool terminal;
}

/// Homebrew artifact naming metadata for a target.
final class HomebrewTargetConfig {
  const HomebrewTargetConfig({
    required this.formulaClass,
    required this.artifactPrefix,
  });

  final String formulaClass;
  final String artifactPrefix;
}

/// One independently versioned package or application.
final class ReleaseTargetConfig {
  const ReleaseTargetConfig({
    required this.name,
    required this.kind,
    required this.root,
    required this.version,
    required this.tagTemplate,
    required this.commitTemplate,
    required this.branch,
    this.changelog,
    this.product,
    this.payload,
    this.windows,
    this.macos,
    this.linux,
    this.homebrew,
  });

  final String name;
  final ShipworldTargetKind kind;
  final String root;
  final VersionConfig version;
  final String tagTemplate;
  final String commitTemplate;
  final String branch;
  final String? changelog;
  final ProductConfig? product;
  final PayloadConfig? payload;
  final WindowsTargetConfig? windows;
  final MacosTargetConfig? macos;
  final LinuxTargetConfig? linux;
  final HomebrewTargetConfig? homebrew;

  String versionPath(String repoRoot) =>
      _resolveWithin(repoRoot, p.join(root, version.pubspecPath), 'version');

  String targetPath(String repoRoot, String relative, String label) =>
      _resolveWithin(repoRoot, p.join(root, relative), label);

  String renderTag(String value) =>
      tagTemplate.replaceAll('{version}', value.split('+').first);

  String renderCommit(String value) => commitTemplate
      .replaceAll('{name}', name)
      .replaceAll('{version}', value.split('+').first);
}

/// Parsed schema-v1 root configuration.
final class ShipworldConfig {
  const ShipworldConfig({
    required this.path,
    required this.remote,
    required this.batchCommitTemplate,
    required this.targets,
  });

  static const int supportedSchema = 1;

  final String path;
  final String remote;
  final String batchCommitTemplate;
  final Map<String, ReleaseTargetConfig> targets;

  String get repoRoot => p.dirname(path);

  ReleaseTargetConfig target(String name) {
    final value = targets[name];
    if (value == null) {
      throw ShipworldException(
        'Unknown release target: $name',
        code: 'unknown_target',
      );
    }
    return value;
  }

  String renderBatchCommit(Iterable<({String name, String version})> values) {
    final rendered = values
        .map((value) => '${value.name} ${value.version.split('+').first}')
        .join(', ');
    return batchCommitTemplate.replaceAll('{targets}', rendered);
  }
}

Map<Object?, Object?> _map(Object? value, String label) {
  if (value is YamlMap) return value;
  if (value is Map<Object?, Object?>) return value;
  throw ShipworldException('$label must be a map', code: 'invalid_config');
}

void _onlyKeys(Map<Object?, Object?> map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw ShipworldException(
        '$label contains unknown field: $key',
        code: 'invalid_config',
      );
    }
  }
}

String _requiredString(Map<Object?, Object?> map, String key, String label) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw ShipworldException(
      '$label.$key must be a non-empty string',
      code: 'invalid_config',
    );
  }
  return value;
}

String? _optionalString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw ShipworldException(
      '$key must be a non-empty string',
      code: 'invalid_config',
    );
  }
  return value;
}

bool _requiredBool(Map<Object?, Object?> map, String key, String label) {
  final value = map[key];
  if (value is! bool) {
    throw ShipworldException(
      '$label.$key must be a boolean',
      code: 'invalid_config',
    );
  }
  return value;
}

String _relativePath(String value, String label) {
  if (p.isAbsolute(value) ||
      p.split(value).contains('..') ||
      value.trim().isEmpty) {
    throw ShipworldException(
      '$label must be a relative path without "..": $value',
      code: 'invalid_path',
    );
  }
  return p.normalize(value);
}

String _launcherPath(String value, String label) => _relativePath(value, label);

String _resolveWithin(String root, String relative, String label) {
  final resolvedRoot = p.normalize(p.absolute(root));
  final resolved = p.normalize(p.absolute(p.join(resolvedRoot, relative)));
  if (resolved != resolvedRoot && !p.isWithin(resolvedRoot, resolved)) {
    throw ShipworldException(
      '$label resolves outside the repository: $relative',
      code: 'invalid_path',
    );
  }
  return resolved;
}

List<String> _stringList(Object? value, String label) {
  if (value is! Iterable<Object?>) {
    throw ShipworldException('$label must be a list', code: 'invalid_config');
  }
  return [
    for (final item in value)
      if (item is String && item.trim().isNotEmpty)
        item
      else
        throw ShipworldException(
          '$label entries must be non-empty strings',
          code: 'invalid_config',
        ),
  ];
}

VersionConfig _parseVersion(Map<Object?, Object?> target, String label) {
  final map = _map(target['version'], '$label.version');
  _onlyKeys(map, const {'source', 'synchronized'}, '$label.version');
  final synchronized = <SynchronizedVersionConfig>[];
  final raw = map['synchronized'];
  if (raw != null) {
    if (raw is! Iterable<Object?>) {
      throw ShipworldException(
        '$label.version.synchronized must be a list',
        code: 'invalid_config',
      );
    }
    for (final item in raw) {
      final writer = _map(item, '$label.version.synchronized');
      _onlyKeys(writer, const {
        'type',
        'path',
        'constant',
      }, '$label.version.synchronized');
      synchronized.add(
        SynchronizedVersionConfig(
          kind: VersionWriterKind.parse(
            _requiredString(writer, 'type', '$label.version.synchronized'),
          ),
          path: _relativePath(
            _requiredString(writer, 'path', '$label.version.synchronized'),
            '$label.version.synchronized.path',
          ),
          constant: _optionalString(writer, 'constant') ?? 'packageVersion',
        ),
      );
    }
  }
  return VersionConfig(
    pubspecPath: _relativePath(
      _requiredString(map, 'source', '$label.version'),
      '$label.version.source',
    ),
    synchronized: List.unmodifiable(synchronized),
  );
}

ProductConfig? _parseProduct(Map<Object?, Object?> target, String label) {
  if (target['product'] == null) return null;
  final map = _map(target['product'], '$label.product');
  _onlyKeys(map, const {
    'name',
    'display-name',
    'description',
    'executable',
    'homepage',
    'repository',
  }, '$label.product');
  return ProductConfig(
    name: _requiredString(map, 'name', '$label.product'),
    displayName: _requiredString(map, 'display-name', '$label.product'),
    description: _requiredString(map, 'description', '$label.product'),
    executable: _requiredString(map, 'executable', '$label.product'),
    homepage: _optionalString(map, 'homepage'),
    repository: _optionalString(map, 'repository'),
  );
}

PayloadConfig? _parsePayload(Map<Object?, Object?> target, String label) {
  if (target['payload'] == null) return null;
  final map = _map(target['payload'], '$label.payload');
  _onlyKeys(map, const {'kind', 'launcher'}, '$label.payload');
  return PayloadConfig(
    kind: PayloadKind.parse(_requiredString(map, 'kind', '$label.payload')),
    launcher: _launcherPath(
      _requiredString(map, 'launcher', '$label.payload'),
      '$label.payload.launcher',
    ),
  );
}

WindowsTargetConfig? _parseWindows(Map<Object?, Object?> target, String label) {
  if (target['windows'] == null) return null;
  final map = _map(target['windows'], '$label.windows');
  _onlyKeys(map, const {
    'application-id',
    'executable',
    'background-color',
    'identity',
  }, '$label.windows');
  final identity = _map(map['identity'], '$label.windows.identity');
  _onlyKeys(identity, const {
    'name-env',
    'publisher-env',
    'publisher-display-name-env',
    'display-name-env',
  }, '$label.windows.identity');
  final applicationId = _requiredString(
    map,
    'application-id',
    '$label.windows',
  );
  if (!RegExp(
    r'^([A-Za-z][A-Za-z0-9]*)(\.[A-Za-z][A-Za-z0-9]*)*$',
  ).hasMatch(applicationId)) {
    throw ShipworldException(
      '$label.windows.application-id is not MSIX-compatible: $applicationId',
      code: 'invalid_config',
    );
  }
  return WindowsTargetConfig(
    applicationId: applicationId,
    executable: _launcherPath(
      _requiredString(map, 'executable', '$label.windows'),
      '$label.windows.executable',
    ),
    backgroundColor: _optionalString(map, 'background-color') ?? 'transparent',
    identityEnvironment: WindowsIdentityEnvironmentConfig(
      name: _requiredString(identity, 'name-env', '$label.windows.identity'),
      publisher: _requiredString(
        identity,
        'publisher-env',
        '$label.windows.identity',
      ),
      publisherDisplayName: _requiredString(
        identity,
        'publisher-display-name-env',
        '$label.windows.identity',
      ),
      displayName: _optionalString(identity, 'display-name-env'),
    ),
  );
}

MacosTargetConfig? _parseMacos(Map<Object?, Object?> target, String label) {
  if (target['macos'] == null) return null;
  final map = _map(target['macos'], '$label.macos');
  _onlyKeys(map, const {'entitlements'}, '$label.macos');
  return MacosTargetConfig(
    entitlements: switch (_optionalString(map, 'entitlements')) {
      final value? => _relativePath(value, '$label.macos.entitlements'),
      null => null,
    },
  );
}

LinuxTargetConfig? _parseLinux(Map<Object?, Object?> target, String label) {
  if (target['linux'] == null) return null;
  final map = _map(target['linux'], '$label.linux');
  _onlyKeys(map, const {'icon', 'categories', 'terminal'}, '$label.linux');
  return LinuxTargetConfig(
    icon: _requiredString(map, 'icon', '$label.linux'),
    categories: List.unmodifiable(
      _stringList(map['categories'], '$label.linux.categories'),
    ),
    terminal: _requiredBool(map, 'terminal', '$label.linux'),
  );
}

HomebrewTargetConfig? _parseHomebrew(
  Map<Object?, Object?> target,
  String label,
) {
  if (target['homebrew'] == null) return null;
  final map = _map(target['homebrew'], '$label.homebrew');
  _onlyKeys(map, const {'formula-class', 'artifact-prefix'}, '$label.homebrew');
  return HomebrewTargetConfig(
    formulaClass: _requiredString(map, 'formula-class', '$label.homebrew'),
    artifactPrefix: _requiredString(map, 'artifact-prefix', '$label.homebrew'),
  );
}

/// Loads and validates a schema-v1 `shipworld.yaml` file.
Future<ShipworldConfig> loadShipworldConfig(String configPath) async {
  final resolved = p.normalize(p.absolute(configPath));
  final file = File(resolved);
  if (!await file.exists()) {
    throw ShipworldException(
      'shipworld config not found: $resolved',
      code: 'config_not_found',
    );
  }

  Object? document;
  try {
    document = loadYaml(await file.readAsString());
  } on YamlException catch (error) {
    throw ShipworldException(
      'Invalid shipworld YAML: ${error.message}',
      code: 'invalid_config',
    );
  }

  final root = _map(document, 'shipworld config');
  _onlyKeys(root, const {
    'schema',
    'remote',
    'batch-commit',
    'targets',
  }, 'shipworld config');
  if (root['schema'] != ShipworldConfig.supportedSchema) {
    throw ShipworldException(
      'shipworld config schema must be ${ShipworldConfig.supportedSchema}',
      code: 'unsupported_schema',
    );
  }

  final targetsMap = _map(root['targets'], 'targets');
  final targets = <String, ReleaseTargetConfig>{};
  for (final entry in targetsMap.entries) {
    if (entry.key is! String || (entry.key! as String).trim().isEmpty) {
      throw const ShipworldException(
        'target names must be non-empty strings',
        code: 'invalid_config',
      );
    }
    final name = entry.key! as String;
    final label = 'targets.$name';
    final target = _map(entry.value, label);
    _onlyKeys(target, const {
      'kind',
      'root',
      'version',
      'changelog',
      'tag',
      'commit',
      'branch',
      'product',
      'payload',
      'windows',
      'macos',
      'linux',
      'homebrew',
    }, label);
    final targetRoot = _relativePath(
      _requiredString(target, 'root', label),
      '$label.root',
    );
    final parsed = ReleaseTargetConfig(
      name: name,
      kind: ShipworldTargetKind.parse(_requiredString(target, 'kind', label)),
      root: targetRoot,
      version: _parseVersion(target, label),
      tagTemplate: _requiredString(target, 'tag', label),
      commitTemplate: _requiredString(target, 'commit', label),
      branch: _requiredString(target, 'branch', label),
      changelog: switch (_optionalString(target, 'changelog')) {
        final value? => _relativePath(value, '$label.changelog'),
        null => null,
      },
      product: _parseProduct(target, label),
      payload: _parsePayload(target, label),
      windows: _parseWindows(target, label),
      macos: _parseMacos(target, label),
      linux: _parseLinux(target, label),
      homebrew: _parseHomebrew(target, label),
    );
    parsed.versionPath(p.dirname(resolved));
    for (final writer in parsed.version.synchronized) {
      parsed.targetPath(
        p.dirname(resolved),
        writer.path,
        '$label.version.synchronized.path',
      );
    }
    if (parsed.changelog case final changelog?) {
      parsed.targetPath(p.dirname(resolved), changelog, '$label.changelog');
    }
    if (parsed.macos?.entitlements case final entitlements?) {
      parsed.targetPath(
        p.dirname(resolved),
        entitlements,
        '$label.macos.entitlements',
      );
    }
    if (parsed.linux case final linux?) {
      _resolveWithin(
        p.dirname(resolved),
        p.join(targetRoot, linux.icon),
        '$label.linux.icon',
      );
    }
    if (!parsed.tagTemplate.contains('{version}')) {
      throw ShipworldException(
        '$label.tag must contain {version}',
        code: 'invalid_config',
      );
    }
    targets[name] = parsed;
  }

  if (targets.isEmpty) {
    throw const ShipworldException(
      'shipworld config must define targets',
      code: 'invalid_config',
    );
  }
  final batchCommit = _requiredString(root, 'batch-commit', 'shipworld config');
  if (!batchCommit.contains('{targets}')) {
    throw const ShipworldException(
      'shipworld config.batch-commit must contain {targets}',
      code: 'invalid_config',
    );
  }
  return ShipworldConfig(
    path: resolved,
    remote: _requiredString(root, 'remote', 'shipworld config'),
    batchCommitTemplate: batchCommit,
    targets: Map.unmodifiable(targets),
  );
}
