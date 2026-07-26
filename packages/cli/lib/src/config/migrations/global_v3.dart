/// Mirror of `migrations/global-v3.ts`: drops the legacy `age` section and
/// bumps the global config version to 3.
Map<String, Object?> migrateGlobalConfigV2ToV3(Map<String, Object?> config) {
  return {
    for (final entry in config.entries)
      if (entry.key != 'age') entry.key: entry.value,
    'version': 3,
  };
}
