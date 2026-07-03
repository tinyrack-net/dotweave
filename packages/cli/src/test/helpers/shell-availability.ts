import { execFileSync } from "node:child_process";

const getShellPath = (shell: string): string | undefined => {
  const lookupCommand = process.platform === "win32" ? "where" : "which";
  const isUnsupportedWindowsShell =
    process.platform === "win32" && shell === "bash";

  try {
    return execFileSync(lookupCommand, [shell], { encoding: "utf8" })
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .find((line) => {
        if (line.length === 0) {
          return false;
        }

        return !(
          isUnsupportedWindowsShell &&
          /\\(?:Windows\\System32|Microsoft\\WindowsApps)\\bash\.exe$/iu.test(
            line,
          )
        );
      });
  } catch {
    return undefined;
  }
};

export const bashPath = getShellPath("bash");
export const fishPath = getShellPath("fish");
export const powerShellPath =
  getShellPath("pwsh") ?? getShellPath("powershell");
export const zshPath = getShellPath("zsh");

export const isBashAvailable = bashPath !== undefined;
export const isFishAvailable = fishPath !== undefined;
export const isPowerShellAvailable = powerShellPath !== undefined;
export const isZshAvailable = zshPath !== undefined;
