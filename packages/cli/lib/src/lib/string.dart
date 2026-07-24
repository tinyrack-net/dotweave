String? normalizeConfiguredValue(String? value) {
  final trimmedValue = value?.trim();

  return trimmedValue == null || trimmedValue.isEmpty ? null : trimmedValue;
}

String ensureTrailingNewline(String value) {
  return value.endsWith('\n') ? value : '$value\n';
}
