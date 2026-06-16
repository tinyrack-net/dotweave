import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { DotweaveError, wrapUnknownError } from "#app/lib/error.ts";

const execFileAsync = promisify(execFile);

type GitCommandOptions = Readonly<{ cwd?: string }>;

type GitExecFileAsync = (
  file: string,
  args: readonly string[],
  options: Readonly<{
    cwd?: string;
    encoding: "utf8";
    maxBuffer: number;
  }>,
) => Promise<{
  stderr: string;
  stdout: string;
}>;

type GitStreamingChild = Readonly<{
  stderr?: {
    on: (event: "data", listener: (chunk: string) => void) => unknown;
    setEncoding: (encoding: BufferEncoding) => void;
  };
  stdout?: {
    on: (event: "data", listener: (chunk: string) => void) => unknown;
    setEncoding: (encoding: BufferEncoding) => void;
  };
  on: {
    (event: "error", listener: (error: unknown) => void): unknown;
    (event: "close", listener: (code: number | null) => void): unknown;
  };
}>;

type GitSpawn = (
  command: string,
  args: readonly string[],
  options: Readonly<{
    cwd?: string;
    stdio: ["ignore", "pipe", "pipe"];
  }>,
) => GitStreamingChild;

type GitCommandDependencies = Readonly<{
  execFileAsync: GitExecFileAsync;
}>;

type StreamingGitCommandDependencies = Readonly<{
  spawnGit: GitSpawn;
}>;

const missingGitExecutableCode = "GIT_EXECUTABLE_NOT_FOUND";

const isEnoentError = (error: unknown) => {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as Error & { code?: unknown }).code === "ENOENT"
  );
};

const createMissingGitExecutableError = () => {
  return new DotweaveError("Git is not installed or not on PATH.", {
    code: missingGitExecutableCode,
    hint: "Install Git and ensure the git executable is available on PATH, then run dotweave again.",
  });
};

export const isMissingGitExecutableError = (error: unknown) => {
  return (
    error instanceof DotweaveError && error.code === missingGitExecutableCode
  );
};

/**
 * @description
 * Runs a git command and normalizes failures into concise errors.
 */
export const runGitCommandWithDependencies = async (
  args: readonly string[],
  options: GitCommandOptions | undefined,
  dependencies: GitCommandDependencies,
) => {
  try {
    const result = await dependencies.execFileAsync("git", [...args], {
      cwd: options?.cwd,
      encoding: "utf8",
      maxBuffer: 10_000_000,
    });

    return {
      stderr: result.stderr,
      stdout: result.stdout,
    };
  } catch (error: unknown) {
    if (isEnoentError(error)) {
      throw createMissingGitExecutableError();
    }

    if (error instanceof Error && "stderr" in error) {
      const stderr =
        typeof error.stderr === "string" ? error.stderr.trim() : undefined;
      const stdout =
        "stdout" in error && typeof error.stdout === "string"
          ? error.stdout.trim()
          : undefined;
      const message = stderr || stdout || error.message;

      throw new Error(message);
    }

    throw new Error(error instanceof Error ? error.message : "git failed.");
  }
};

const runGitCommand = async (
  args: readonly string[],
  options?: GitCommandOptions,
) => {
  return await runGitCommandWithDependencies(args, options, {
    execFileAsync: execFileAsync as GitExecFileAsync,
  });
};

/**
 * @description
 * Runs a git command while collecting output.
 */
export const runStreamingGitCommandWithDependencies = async (
  args: readonly string[],
  options: GitCommandOptions | undefined,
  dependencies: StreamingGitCommandDependencies,
) => {
  return await new Promise<{
    stderr: string;
    stdout: string;
  }>((resolve, reject) => {
    const child = dependencies.spawnGit("git", [...args], {
      cwd: options?.cwd,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let settled = false;
    let stdout = "";
    let stderr = "";

    const finish = (handler: () => void) => {
      if (settled) {
        return;
      }

      settled = true;
      handler();
    };

    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish(() => {
        reject(
          isEnoentError(error)
            ? createMissingGitExecutableError()
            : new Error(error instanceof Error ? error.message : "git failed."),
        );
      });
    });
    child.on("close", (code) => {
      if (code === 0) {
        finish(() => {
          resolve({ stderr, stdout });
        });

        return;
      }

      finish(() => {
        reject(
          new Error(
            stderr.trim() ||
              stdout.trim() ||
              `git exited with code ${code ?? "unknown"}.`,
          ),
        );
      });
    });
  });
};

const runStreamingGitCommand = async (
  args: readonly string[],
  options?: GitCommandOptions,
) => {
  return await runStreamingGitCommandWithDependencies(args, options, {
    spawnGit: spawn as GitSpawn,
  });
};

/**
 * @description
 * Verifies that a directory is already a git working tree.
 */
export const verifyIsGitRepository = async (directory: string) => {
  await runGitCommand(["-C", directory, "rev-parse", "--is-inside-work-tree"]);
};

/**
 * @description
 * Creates a sync directory locally or clones it from a remote source.
 */
export const initializeRepository = async (
  directory: string,
  source?: string,
) => {
  if (source === undefined) {
    await runStreamingGitCommand(["init", "-b", "main", directory]);

    return {
      action: "initialized" as const,
    };
  }

  await runStreamingGitCommand(["clone", source, directory]);

  return {
    action: "cloned" as const,
    source,
  };
};

/**
 * @description
 * Ensures the sync directory is a usable git repository for dotweave commands.
 */
export const requireGitRepository = async (syncDirectory: string) => {
  try {
    await verifyIsGitRepository(syncDirectory);
  } catch (error: unknown) {
    throw wrapUnknownError("Sync repository is not initialized.", error, {
      code: "SYNC_REPO_INVALID",
      details: [`Sync directory: ${syncDirectory}`],
      hint: "Run 'dotweave init' to create or clone the sync directory.",
    });
  }
};
