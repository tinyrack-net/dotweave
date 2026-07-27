import 'dart:io';

import 'package:cliweave/cliweave.dart';
import 'package:path/path.dart' as p;

import '../homebrew.dart';
import '../linux.dart';
import '../macos.dart';
import '../windows.dart';
import 'config.dart';
import 'context.dart';
import 'error.dart';
import 'payload.dart';
import 'release.dart';
import 'version.dart';
import 'version_files.dart';

const _configFlag = ParsedFlag(
  brief: 'Path to shipworld.yaml',
  parse: stringParser,
  optional: true,
  defaultValue: 'shipworld.yaml',
);

ParsedFlag _requiredFlag(String brief) =>
    ParsedFlag(brief: brief, parse: stringParser, optional: false);

ParsedFlag _optionalFlag(String brief) =>
    ParsedFlag(brief: brief, parse: stringParser, optional: true);

String _required(Map<String, Object?> flags, String name) =>
    flags[name]! as String;

String? _optional(Map<String, Object?> flags, String name) =>
    flags[name] as String?;

String _targetName(List<Object?> positional) => positional.single! as String;

final class _CliLogger implements ShipworldLogger {
  const _CliLogger(this.process);

  final RunProcess process;

  @override
  void info(String message) => process.stdout.write('$message\n');

  @override
  void progress(String message) => process.stdout.write('$message\n');
}

ShipworldContext _context(RunContext context) {
  return ShipworldContext(
    environment: Map<String, String>.unmodifiable(Platform.environment),
    logger: _CliLogger(context.process),
  );
}

Future<({ShipworldConfig config, ReleaseTargetConfig target})> _loadTarget(
  Map<String, Object?> flags,
  List<Object?> positional,
) async {
  final config = await loadShipworldConfig(_required(flags, 'config'));
  return (config: config, target: config.target(_targetName(positional)));
}

ArtifactPayload _payload(
  ReleaseTargetConfig target,
  String input,
  String? launcher,
) {
  final configured = target.payload;
  final resolvedLauncher =
      launcher ?? configured?.launcher ?? target.product?.executable;
  if (resolvedLauncher == null) {
    throw ShipworldException(
      'Target ${target.name} must configure payload.launcher or product',
      code: 'invalid_config',
    );
  }
  return switch (configured?.kind ?? PayloadKind.executable) {
    PayloadKind.executable => ExecutablePayload(
      executablePath: input,
      executableName: resolvedLauncher,
    ),
    PayloadKind.directory => DirectoryPayload(
      directoryPath: input,
      launcherRelativePath: resolvedLauncher,
    ),
  };
}

final _prepareCommand = buildCommand(
  docs: const CommandDocs(brief: 'Prepare an atomic release commit'),
  parameters: const CommandParameters(
    flags: {
      'config': _configFlag,
      'dryRun': BooleanFlag(
        brief: 'Report changes without writing',
        optional: true,
      ),
    },
    positional: ArrayPositionalParameters(
      minimum: 1,
      parameter: PositionalParameter(
        brief: 'Target and bump, for example cliweave=patch',
        parse: stringParser,
        placeholder: 'target=bump',
      ),
    ),
  ),
  func: (context, flags, positional) async {
    final config = await loadShipworldConfig(_required(flags, 'config'));
    final bumps = <String, ReleaseType>{};
    for (final value in positional) {
      final text = value! as String;
      final parts = text.split('=');
      if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
        throw ShipworldException(
          'Invalid release selection: $value',
          code: 'invalid_argument',
        );
      }
      bumps[parts.first] = parseReleaseType(parts.last);
    }
    final result = await ReleaseService(
      config: config,
      context: _context(context),
    ).prepare(bumps: bumps, dryRun: flags['dryRun'] == true);
    for (final target in result.targets) {
      context.process.stdout.write(
        '${result.dryRun ? 'Would prepare' : 'Prepared'} '
        '${target.name} ${target.version} (${target.tag})\n',
      );
    }
    return null;
  },
);

final _finalizeCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Create signed tags from verified remote HEAD',
  ),
  parameters: const CommandParameters(
    flags: {
      'config': _configFlag,
      'push': BooleanFlag(
        brief: 'Atomically push created tags',
        optional: true,
      ),
    },
    positional: ArrayPositionalParameters(
      minimum: 1,
      parameter: PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ),
  ),
  func: (context, flags, positional) async {
    final config = await loadShipworldConfig(_required(flags, 'config'));
    final result =
        await ReleaseService(
          config: config,
          context: _context(context),
        ).finalize(
          targetNames: [for (final value in positional) value! as String],
          push: flags['push'] == true,
        );
    context.process.stdout.write(
      'Finalized ${result.tags.join(', ')} at ${result.head}\n',
    );
    return null;
  },
);

final _verifyCommand = buildCommand(
  docs: const CommandDocs(brief: 'Verify a CI tag against a target version'),
  parameters: const CommandParameters(
    flags: {'config': _configFlag},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final config = await loadShipworldConfig(_required(flags, 'config'));
    final tag = await ReleaseService(
      config: config,
      context: _context(context),
    ).verify(_targetName(positional));
    context.process.stdout.write('Verified $tag\n');
    return null;
  },
);

final _msixCommand = buildCommand(
  docs: const CommandDocs(brief: 'Build an MSIX from a prebuilt payload'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'input': _requiredFlag('Executable or directory payload path'),
      'output': _requiredFlag('Output .msix path'),
      'packageRoot': _requiredFlag('MSIX staging directory'),
      'arch': _requiredFlag('MSIX architecture: x64 or arm64'),
      'launcher': _optionalFlag('Payload launcher override'),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final target = loaded.target;
    final product = target.product;
    final windows = target.windows;
    if (product == null || windows == null) {
      throw ShipworldException(
        'Target ${target.name} must configure product and windows',
        code: 'invalid_config',
      );
    }
    final env = _context(context).environment;
    String envValue(String name) {
      final value = env[name];
      if (value == null || value.trim().isEmpty) {
        throw ShipworldException(
          '$name is required to build Windows MSIX packages',
          code: 'missing_credential',
        );
      }
      return value;
    }

    final identityEnvironment = windows.identityEnvironment;
    final displayNameEnv = identityEnvironment.displayName;
    final version = await readPubspecVersion(
      target.versionPath(loaded.config.repoRoot),
    );
    final result = await WindowsPackagingService(_context(context))
        .buildPackage(
          arch: parseMsixArchitecture(_required(flags, 'arch')),
          payload: _payload(
            target,
            _required(flags, 'input'),
            _optional(flags, 'launcher') ?? windows.executable,
          ),
          config: MsixConfig(
            applicationId: windows.applicationId,
            displayName: product.displayName,
            description: product.description,
            executableName: windows.executable,
            backgroundColor: windows.backgroundColor,
          ),
          identity: MsixIdentity(
            identityName: envValue(identityEnvironment.name),
            publisher: envValue(identityEnvironment.publisher),
            publisherDisplayName: envValue(
              identityEnvironment.publisherDisplayName,
            ),
            displayName: displayNameEnv == null ? null : env[displayNameEnv],
          ),
          version: version,
          repoRoot: loaded.config.repoRoot,
          outputPath: _required(flags, 'output'),
          packageRoot: _required(flags, 'packageRoot'),
        );
    context.process.stdout.write('Built ${result.outputPath}\n');
    return null;
  },
);

final _msixBundleCommand = buildCommand(
  docs: const CommandDocs(brief: 'Bundle architecture-specific MSIX packages'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'packageDir': _requiredFlag('Directory containing .msix packages'),
      'output': _requiredFlag('Output .msixbundle path'),
      'workingDirectory': _requiredFlag('Temporary bundle directory'),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final version = await readPubspecVersion(
      loaded.target.versionPath(loaded.config.repoRoot),
    );
    final output = await WindowsPackagingService(_context(context)).buildBundle(
      repoRoot: loaded.config.repoRoot,
      version: version,
      packageDir: _required(flags, 'packageDir'),
      outputPath: _required(flags, 'output'),
      workingDirectory: _required(flags, 'workingDirectory'),
    );
    context.process.stdout.write('Built $output\n');
    return null;
  },
);

final _macosSignCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Sign and optionally notarize a macOS payload',
  ),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'input': _requiredFlag('Executable or .app path'),
      'entitlements': _optionalFlag('Entitlements path override'),
      'appBundle': BooleanFlag(
        brief: 'Treat input as a Flutter .app bundle',
        optional: true,
      ),
      'skipNotarize': BooleanFlag(
        brief: 'Use ad-hoc signing without notarization',
        optional: true,
      ),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final configured = loaded.target.macos?.entitlements;
    final entitlements =
        _optional(flags, 'entitlements') ??
        (configured == null
            ? null
            : loaded.target.targetPath(
                loaded.config.repoRoot,
                configured,
                'macos entitlements',
              ));
    if (entitlements == null) {
      throw ShipworldException(
        'Target ${loaded.target.name} must configure macos.entitlements',
        code: 'invalid_config',
      );
    }
    await MacosPackagingService(_context(context)).sign(
      MacosSignConfig(
        inputPath: _required(flags, 'input'),
        entitlementsPath: entitlements,
        skipNotarize: flags['skipNotarize'] == true,
        isAppBundle: flags['appBundle'] == true,
        environment: _context(context).environment,
      ),
    );
    context.process.stdout.write('Signed ${_required(flags, 'input')}\n');
    return null;
  },
);

final _macosArchiveCommand = buildCommand(
  docs: const CommandDocs(brief: 'Archive a signed macOS application'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'input': _requiredFlag('Signed .app path'),
      'output': _requiredFlag('Output zip path'),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    await _loadTarget(flags, positional);
    final output = await MacosPackagingService(_context(context)).archive(
      appPath: _required(flags, 'input'),
      outputPath: _required(flags, 'output'),
    );
    context.process.stdout.write('Archived $output\n');
    return null;
  },
);

final _appImageCommand = buildCommand(
  docs: const CommandDocs(brief: 'Build an AppImage from a prebuilt payload'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'input': _requiredFlag('Executable or directory payload path'),
      'output': _requiredFlag('Output AppImage path'),
      'arch': _requiredFlag('AppImage architecture'),
      'tool': _optionalFlag('Explicit appimagetool path'),
      'launcher': _optionalFlag('Payload launcher override'),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final target = loaded.target;
    final product = target.product;
    final linux = target.linux;
    if (product == null || linux == null) {
      throw ShipworldException(
        'Target ${target.name} must configure product and linux',
        code: 'invalid_config',
      );
    }
    final arch = _required(flags, 'arch');
    final env = _context(context).environment;
    await LinuxPackagingService(_context(context)).build(
      repoRoot: loaded.config.repoRoot,
      payload: _payload(
        target,
        _required(flags, 'input'),
        _optional(flags, 'launcher'),
      ),
      config: AppImageConfig(
        name: product.name,
        displayName: product.displayName,
        iconPath: p.normalize(
          p.join(loaded.config.repoRoot, target.root, linux.icon),
        ),
        categories: linux.categories,
        terminal: linux.terminal,
      ),
      outputPath: _required(flags, 'output'),
      arch: arch,
      appImageToolPath:
          _optional(flags, 'tool') ??
          env['APPIMAGETOOL_PATH'] ??
          'appimagetool-$arch.AppImage',
    );
    context.process.stdout.write('Built ${_required(flags, 'output')}\n');
    return null;
  },
);

final _formulaCommand = buildCommand(
  docs: const CommandDocs(brief: 'Generate a Homebrew Formula'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'artifactsDir': _requiredFlag('Directory containing release artifacts'),
      'output': _requiredFlag('Output Formula path'),
      'versionedOutput': _optionalFlag(
        'Optional output path for a versioned Formula',
      ),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final target = loaded.target;
    final product = target.product;
    final homebrew = target.homebrew;
    if (product == null ||
        product.homepage == null ||
        product.repository == null ||
        homebrew == null) {
      throw ShipworldException(
        'Target ${target.name} must configure product homepage/repository '
        'and homebrew',
        code: 'invalid_config',
      );
    }
    final version = (await readPubspecVersion(
      target.versionPath(loaded.config.repoRoot),
    )).split('+').first;
    final artifactsDir = _required(flags, 'artifactsDir');
    final artifacts = <HomebrewArtifact>[];
    for (final entry in const [
      ('macos', 'arm64'),
      ('macos', 'x64'),
      ('linux', 'arm64'),
      ('linux', 'x64'),
    ]) {
      final fileName = '${homebrew.artifactPrefix}-${entry.$1}-${entry.$2}';
      final filePath = p.join(artifactsDir, fileName);
      artifacts.add(
        HomebrewArtifact(
          platform: entry.$1,
          architecture: entry.$2,
          url:
              'https://github.com/${product.repository}/releases/download/'
              '${target.renderTag(version)}/$fileName',
          sha256: await calculateSha256(filePath),
          fileName: fileName,
        ),
      );
    }
    HomebrewFormulaConfig formulaConfig({
      required String className,
      bool versioned = false,
    }) {
      return HomebrewFormulaConfig(
        className: className,
        description: product.description,
        homepage: product.homepage!,
        version: version,
        executableName: product.executable,
        versioned: versioned,
      );
    }

    final output = _required(flags, 'output');
    final formula = generateConfigurableHomebrewFormula(
      config: formulaConfig(className: homebrew.formulaClass),
      artifacts: artifacts,
    );
    await Directory(p.dirname(output)).create(recursive: true);
    await File(output).writeAsString(formula);

    final versionedOutput = _optional(flags, 'versionedOutput');
    if (versionedOutput == null) {
      context.process.stdout.write('Generated $output\n');
      return null;
    }

    final classVersion = version.replaceAll(RegExp('[^0-9A-Za-z]'), '');
    final versionedFormula = generateConfigurableHomebrewFormula(
      config: formulaConfig(
        className: '${homebrew.formulaClass}AT$classVersion',
        versioned: true,
      ),
      artifacts: artifacts,
    );
    await Directory(p.dirname(versionedOutput)).create(recursive: true);
    await File(versionedOutput).writeAsString(versionedFormula);
    context.process.stdout.write('Generated $output and $versionedOutput\n');
    return null;
  },
);

final _caskCommand = buildCommand(
  docs: const CommandDocs(brief: 'Generate a Homebrew Cask'),
  parameters: CommandParameters(
    flags: {
      'config': _configFlag,
      'archive': _requiredFlag('Signed macOS application archive'),
      'url': _requiredFlag('Public archive URL'),
      'output': _requiredFlag('Output Cask path'),
    },
    positional: const TuplePositionalParameters([
      PositionalParameter(
        brief: 'Release target name',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
  func: (context, flags, positional) async {
    final loaded = await _loadTarget(flags, positional);
    final target = loaded.target;
    final product = target.product;
    if (product == null || product.homepage == null) {
      throw ShipworldException(
        'Target ${target.name} must configure product homepage',
        code: 'invalid_config',
      );
    }
    final version = (await readPubspecVersion(
      target.versionPath(loaded.config.repoRoot),
    )).split('+').first;
    final cask = generateHomebrewCask(
      token: product.name,
      version: version,
      sha256: await calculateSha256(_required(flags, 'archive')),
      url: _required(flags, 'url'),
      appName: product.displayName,
      description: product.description,
      homepage: product.homepage!,
    );
    await File(_required(flags, 'output')).writeAsString(cask);
    context.process.stdout.write('Generated ${_required(flags, 'output')}\n');
    return null;
  },
);

Application _buildShipworldApplication() {
  final releaseRoutes = buildRouteMap(
    docs: const RouteMapDocs(brief: 'Prepare and finalize releases'),
    routes: {
      'prepare': _prepareCommand,
      'finalize': _finalizeCommand,
      'verify': _verifyCommand,
    },
  );
  final packageRoutes = buildRouteMap(
    docs: const RouteMapDocs(brief: 'Build desktop distribution artifacts'),
    routes: {
      'windows': buildRouteMap(
        docs: const RouteMapDocs(brief: 'Windows packaging'),
        routes: {'msix': _msixCommand, 'bundle': _msixBundleCommand},
      ),
      'macos': buildRouteMap(
        docs: const RouteMapDocs(brief: 'macOS signing and archives'),
        routes: {'sign': _macosSignCommand, 'archive': _macosArchiveCommand},
      ),
      'linux': buildRouteMap(
        docs: const RouteMapDocs(brief: 'Linux packaging'),
        routes: {'appimage': _appImageCommand},
      ),
      'homebrew': buildRouteMap(
        docs: const RouteMapDocs(brief: 'Homebrew metadata'),
        routes: {'formula': _formulaCommand, 'cask': _caskCommand},
      ),
    },
  );
  return buildApplication(
    buildRouteMap(
      docs: const RouteMapDocs(
        brief: 'Release and desktop packaging for Dart and Flutter',
      ),
      routes: {'release': releaseRoutes, 'package': packageRoutes},
    ),
    ApplicationConfiguration(
      name: 'shipworld',
      scanner: const ScannerConfiguration(
        caseStyle: ScannerCaseStyle.allowKebabForCamel,
      ),
    ),
  );
}

/// Runs the shipworld command-line application.
Future<int> runShipworld(List<String> args) async {
  final process = RunProcess(
    stdout: StdioWriteStream(stdout),
    stderr: StdioWriteStream(stderr),
  );
  try {
    await run(_buildShipworldApplication(), args, RunContext(process: process));
  } on ShipworldException catch (error) {
    stderr.writeln(error.message);
    return 1;
  }
  return process.exitCode ?? 0;
}
