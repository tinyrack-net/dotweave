/// An expected configuration, release, or packaging failure.
class ShipworldException implements Exception {
  const ShipworldException(this.message, {this.code = 'shipworld_error'});

  /// Human-readable explanation suitable for CLI output.
  final String message;

  /// Stable machine-readable error category.
  final String code;

  @override
  String toString() => message;
}
