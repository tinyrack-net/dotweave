/// Adds command defaults support and bumps the sync config version to 9.
Map<String, Object?> migrateSyncConfigV8ToV9(Map<String, Object?> config) {
  return {...config, 'version': 9};
}
