import { chmod, copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { buildCommand, buildRouteMap } from "@stricli/core";
import { execa } from "execa";
import { getRepoRoot } from "../../lib/git.ts";

export function getAppImageIconPath(repoRoot: string): string {
  return join(repoRoot, "packages/homepage/public/logo.svg");
}

const buildAppImageCommand = buildCommand<
  { executablePath: string; outputPath: string; arch: string },
  []
>({
  parameters: {
    flags: {
      executablePath: {
        kind: "parsed",
        brief: "Path to the executable to wrap in AppImage",
        parse: String,
      },
      outputPath: {
        kind: "parsed",
        brief: "Path where the AppImage should be written",
        parse: String,
      },
      arch: {
        kind: "parsed",
        brief: "Architecture (x86_64, aarch64)",
        parse: String,
      },
    },
  },
  docs: {
    brief: "Build AppImage for Linux",
  },
  async func(flags) {
    const repoRoot = await getRepoRoot(process.cwd());
    const appDir = join(repoRoot, "AppDir");
    const binPath = join(repoRoot, flags.executablePath);
    const appImageToolPath = join(repoRoot, "appimagetool");
    const artifactPath = join(repoRoot, flags.outputPath);

    await rm(appDir, { force: true, recursive: true });
    await mkdir(join(appDir, "usr/bin"), { recursive: true });
    await copyFile(binPath, join(appDir, "usr/bin/dotweave"));
    await chmod(join(appDir, "usr/bin/dotweave"), 0o755);

    await writeFile(
      join(appDir, "dotweave.desktop"),
      `[Desktop Entry]
Name=Dotweave
Exec=dotweave %F
Icon=dotweave
Type=Application
Categories=Utility;
Terminal=true
`,
    );

    await copyFile(getAppImageIconPath(repoRoot), join(appDir, "dotweave.svg"));

    await writeFile(
      join(appDir, "AppRun"),
      `#!/bin/sh
HERE="$(dirname "$(readlink -f "\${0}")")"
export PATH="\${HERE}/usr/bin:\${PATH}"
exec dotweave "$@"
`,
    );
    await chmod(join(appDir, "AppRun"), 0o755);

    const appImageToolName = `appimagetool-${flags.arch}.AppImage`;
    const appImageToolUrl = `https://github.com/AppImage/AppImageKit/releases/download/continuous/${appImageToolName}`;

    console.log(`Downloading ${appImageToolName}...`);
    await execa("wget", [appImageToolUrl, "-O", appImageToolPath]);
    await chmod(appImageToolPath, 0o755);

    console.log("Building AppImage...");
    await execa(
      appImageToolPath,
      ["--appimage-extract-and-run", appDir, artifactPath],
      {
        env: { ARCH: flags.arch },
        cwd: repoRoot,
      },
    );
  },
});

export const appimageRoute = buildRouteMap({
  routes: {
    build: buildAppImageCommand,
  },
  docs: {
    brief: "AppImage commands",
  },
});
