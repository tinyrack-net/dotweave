import 'dart:async';
import 'dart:io';

import 'git.dart';
import 'process.dart';

/// Receives progress messages from Shipworld services.
abstract interface class ShipworldLogger {
  void info(String message);

  void progress(String message);
}

/// Logger that intentionally discards all messages.
final class SilentShipworldLogger implements ShipworldLogger {
  const SilentShipworldLogger();

  @override
  void info(String message) {}

  @override
  void progress(String message) {}
}

/// Immutable external boundaries used by Shipworld operations.
final class ShipworldContext {
  const ShipworldContext({
    this.git = const IoGitClient(),
    this.process = const IoProcessExecutor(),
    this.environment = const {},
    this.logger = const SilentShipworldLogger(),
  });

  /// Git implementation used by release operations.
  final GitClient git;

  /// Child-process implementation used by packaging operations.
  final ProcessExecutor process;

  /// Environment visible to credential and tool resolution.
  final Map<String, String> environment;

  /// Progress sink.
  final ShipworldLogger logger;

  /// Creates a context backed by the current process environment.
  factory ShipworldContext.io({ShipworldLogger? logger}) {
    final environment = Map<String, String>.unmodifiable(Platform.environment);
    return ShipworldContext(
      git: IoGitClient(environment: environment),
      environment: environment,
      logger: logger ?? const SilentShipworldLogger(),
    );
  }

  /// Runs an operation with this context scoped to the current async zone.
  Future<T> run<T>(Future<T> Function() operation) {
    return runZoned(
      () => runWithProcessExecutor(process, operation),
      zoneValues: <Object, Object>{
        _environmentZoneKey: environment,
        _loggerZoneKey: logger,
      },
    );
  }
}

final Object _environmentZoneKey = Object();
final Object _loggerZoneKey = Object();

/// Environment scoped to the current Shipworld operation.
Map<String, String> get currentShipworldEnvironment =>
    Zone.current[_environmentZoneKey] as Map<String, String>? ??
    Platform.environment;

/// Logger scoped to the current Shipworld operation.
ShipworldLogger get currentShipworldLogger =>
    Zone.current[_loggerZoneKey] as ShipworldLogger? ??
    const SilentShipworldLogger();
