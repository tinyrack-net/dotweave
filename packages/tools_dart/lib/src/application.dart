import 'dart:io';

import 'commands/appimage.dart';
import 'commands/homebrew.dart';
import 'commands/msix.dart';
import 'commands/release.dart';
import 'commands/sign.dart';
import 'commands/smoke.dart';
import 'commands/verify.dart';
import 'lib/error.dart';

const String _usage = '''
dotweave repository tools

USAGE
  dart run dotweave_tools:cli <command> [options]

COMMANDS
  release <patch|minor|major> [--dry-run]
      Bump release versions, create a commit and signed tag
  smoke --executable-path <path>
      Run smoke tests on a compiled dotweave executable
  verify release-tag
      Verify that GITHUB_REF_NAME matches the release versions
  sign macos --executable-path <path> [--skip-notarize]
      Sign and notarize a macOS binary
  msix build --arch <x64|arm64> --executable-path <path>
       [--output-path <path>] [--package-root <path>]
      Build a Windows MSIX package for Microsoft Store distribution
  msix bundle [--output-path <path>] [--package-dir <path>]
      Bundle Windows MSIX architecture packages
  appimage build --executable-path <path> --output-path <path> --arch <arch>
      Build AppImage for Linux
  homebrew generate --version <v> --artifacts-dir <dir>
      Generate Homebrew formulas''';

/// Runs the dotweave-tools CLI and returns the process exit code.
Future<int> runTools(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    return 64;
  }

  final command = args.first;
  final rest = args.sublist(1);

  if (command == '--help' || command == '-h' || command == 'help') {
    stdout.writeln(_usage);
    return 0;
  }

  try {
    switch (command) {
      case 'release':
        return await runReleaseCommand(rest);
      case 'smoke':
        return await runSmokeCommand(rest);
      case 'verify':
        return await runVerifyCommand(rest);
      case 'sign':
        return await runSignCommand(rest);
      case 'msix':
        return await runMsixCommand(rest);
      case 'appimage':
        return await runAppimageCommand(rest);
      case 'homebrew':
        return await runHomebrewCommand(rest);
      default:
        stderr.writeln('Unknown command: $command');
        stderr.writeln(_usage);
        return 64;
    }
  } on ToolException catch (error) {
    stderr.writeln(error.message);
    return 1;
  }
}
