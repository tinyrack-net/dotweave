import { chmodSync, realpathSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { stripVTControlCharacters } from "node:util";

const require = createRequire(import.meta.url);

let isPtyFixed = false;

/**
 * On macOS, node-pty's `spawn-helper` binary sometimes lacks the executable bit
 * after installation, leading to "posix_spawnp failed" errors.
 * This function programmatically ensures the executable bit is set for the helper
 * binaries on Darwin platforms.
 */
const fixPtyPermissions = () => {
  if (isPtyFixed || process.platform !== "darwin") {
    return;
  }

  try {
    const ptyRoot = dirname(require.resolve("node-pty/package.json"));
    const helpers = [
      join(ptyRoot, "prebuilds", "darwin-arm64", "spawn-helper"),
      join(ptyRoot, "prebuilds", "darwin-x64", "spawn-helper"),
    ];

    for (const helper of helpers) {
      try {
        const stats = statSync(helper);
        if ((stats.mode & 0o111) !== 0o111) {
          chmodSync(helper, stats.mode | 0o111);
        }
      } catch {
        // Ignore
      }
    }
  } catch {
    // Ignore
  }

  isPtyFixed = true;
};

const applyBackspaces = (value: string) => {
  let result = "";

  for (const character of value) {
    if (character === "\b") {
      result = result.slice(0, -1);
      continue;
    }

    result += character;
  }

  return result;
};

const normalizeTerminalOutput = (value: string) => {
  return applyBackspaces(stripVTControlCharacters(value))
    .replace(/\r\n/gu, "\n")
    .replace(/\r/gu, "\n");
};

export type PtySession = Readonly<{
  clearOutput: () => void;
  close: () => void;
  getOutput: () => string;
  waitFor: (pattern: RegExp | string, timeoutMs?: number) => Promise<string>;
  waitForOutput: (
    predicate: (output: string) => boolean,
    timeoutMs?: number,
  ) => Promise<string>;
  waitForExit: (timeoutMs?: number) => Promise<void>;
  write: (value: string) => void;
}>;

export const createPtyOutputWaiter = (options: {
  getOutput: () => string;
  onOutput: (listener: () => void) => { dispose: () => void };
}) => {
  const waitForOutput = (
    predicate: (output: string) => boolean,
    timeoutMs = 10_000,
  ) => {
    return new Promise<string>((resolve, reject) => {
      const currentOutput = options.getOutput();

      if (predicate(currentOutput)) {
        resolve(currentOutput);
        return;
      }

      let outputSubscription: { dispose: () => void } | undefined;
      const timeout = setTimeout(() => {
        cleanup();
        reject(
          new Error(
            `Timed out waiting for terminal output predicate.\n\n${options.getOutput()}`,
          ),
        );
      }, timeoutMs);

      const cleanup = () => {
        clearTimeout(timeout);
        outputSubscription?.dispose();
      };

      outputSubscription = options.onOutput(() => {
        const nextOutput = options.getOutput();

        if (!predicate(nextOutput)) {
          return;
        }

        cleanup();
        resolve(nextOutput);
      });
    });
  };

  return { waitForOutput };
};

export const createPtySession = (options: {
  args?: readonly string[];
  cwd: string;
  env?: Readonly<Record<string, string | undefined>>;
  file: string;
}): PtySession => {
  fixPtyPermissions();

  const pty = require("node-pty") as typeof import("node-pty");

  const cleanEnv: Record<string, string> = {};

  for (const [key, value] of Object.entries({
    ...process.env,
    ...options.env,
  })) {
    if (value !== undefined) {
      cleanEnv[key] = value;
    }
  }

  const terminal = pty.spawn(options.file, [...(options.args ?? [])], {
    cols: 120,
    // On macOS, the temporary directory /var is a symlink to /private/var.
    // node-pty (posix_spawn) can fail if the CWD is a symlinked path.
    // We resolve it to the real path to ensure stability.
    cwd: realpathSync(options.cwd),
    env: {
      ...cleanEnv,
      TERM: "xterm-256color",
    },
    name: "xterm-256color",
    rows: 40,
  });

  let output = "";
  let exitCode: number | undefined;

  terminal.onData((chunk) => {
    output += chunk;
  });
  terminal.onExit((event) => {
    exitCode = event.exitCode;
  });

  const getOutput = () => {
    return normalizeTerminalOutput(output);
  };
  const outputWaiter = createPtyOutputWaiter({
    getOutput,
    onOutput: (listener) => terminal.onData(listener),
  });

  return {
    clearOutput: () => {
      output = "";
    },
    close: () => {
      terminal.kill();
    },
    getOutput,
    waitFor: (pattern, timeoutMs = 10_000) => {
      return new Promise((resolve, reject) => {
        outputWaiter
          .waitForOutput((normalizedOutput) => {
            return typeof pattern === "string"
              ? normalizedOutput.includes(pattern)
              : pattern.test(normalizedOutput);
          }, timeoutMs)
          .then(resolve, (error: unknown) => {
            reject(
              new Error(
                `Timed out waiting for terminal output matching ${String(pattern)}.\n\n${getOutput()}`,
                { cause: error },
              ),
            );
          });
      });
    },
    waitForOutput: outputWaiter.waitForOutput,
    waitForExit: (timeoutMs = 10_000) => {
      return new Promise((resolve, reject) => {
        if (exitCode !== undefined) {
          resolve();
          return;
        }

        let subscription: { dispose: () => void } | undefined;
        const timeout = setTimeout(() => {
          subscription?.dispose();
          reject(new Error("Timed out waiting for terminal exit."));
        }, timeoutMs);
        subscription = terminal.onExit(() => {
          clearTimeout(timeout);
          subscription?.dispose();
          resolve();
        });
      });
    },
    write: (value) => {
      terminal.write(value);
    },
  };
};
