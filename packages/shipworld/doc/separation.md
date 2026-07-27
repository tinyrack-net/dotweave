# Standalone repository handoff

The package is kept unpublished in the Dotweave workspace while its public
contract is evaluated. To move it to a standalone repository:

1. Copy `packages/shipworld` to the repository root.
2. Remove `resolution: workspace` from `pubspec.yaml`.
3. Remove `publish_to: none` only when pub.dev publishing is approved.
4. Add the repository CI and pub.dev OIDC publishing workflow.
5. Run `dart run tool/validate_standalone.dart` and `pana --no-warning .`.
6. Tag `v0.1.0` only after a second real consumer passes its contract tests.

No Dotweave source, asset, configuration, or test is required by the copied
package.
