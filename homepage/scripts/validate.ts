import { spawn } from "node:child_process";
import { constants } from "node:os";
import { pathToFileURL } from "node:url";

export interface ValidationTask {
  name: string;
  script: string;
}

export interface ValidationTaskResult {
  task: ValidationTask;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
}

export type ValidationTaskRunner = (
  task: ValidationTask,
) => Promise<ValidationTaskResult>;

export type ValidationLogger = (message: string) => void;

const firstStage: ValidationTask[] = [
  { name: "format check", script: "format:check" },
  { name: "unit tests", script: "test" },
  { name: "route typegen", script: "typegen" },
];

const tscTask: ValidationTask = {
  name: "TypeScript compiler",
  script: "typecheck:tsc",
};

const buildTask: ValidationTask = {
  name: "production build",
  script: "build",
};

export function resultExitCode(result: ValidationTaskResult): number {
  if (result.exitCode !== null) {
    return result.exitCode;
  }

  if (result.signal !== null) {
    return 128 + (constants.signals[result.signal] ?? 0);
  }

  return 1;
}

export async function runHomepageValidation({
  runner = runPackageScript,
  log = console.error,
}: {
  runner?: ValidationTaskRunner;
  log?: ValidationLogger;
} = {}): Promise<number> {
  const initialResult = await runStage(firstStage, runner, log);
  if (initialResult !== 0) {
    return initialResult;
  }

  const typecheckResult = await runStage([tscTask], runner, log);
  if (typecheckResult !== 0) {
    return typecheckResult;
  }

  return runStage([buildTask], runner, log);
}

async function runStage(
  tasks: ValidationTask[],
  runner: ValidationTaskRunner,
  log: ValidationLogger,
): Promise<number> {
  for (const task of tasks) {
    log(`[validate] ▶ ${task.name}`);
  }

  const results = await Promise.all(tasks.map(runner));

  for (const result of results) {
    const exitCode = resultExitCode(result);
    if (exitCode === 0) {
      log(`[validate] ✔ ${result.task.name}`);
      continue;
    }

    const outcome =
      result.signal === null
        ? `exit ${exitCode}`
        : `signal ${result.signal}, exit ${exitCode}`;
    log(`[validate] ✖ ${result.task.name} (${outcome})`);
    log(`[validate] runtime: Node ${process.version}, pnpm ${pnpmVersion()}`);
  }

  for (const result of results) {
    const exitCode = resultExitCode(result);
    if (exitCode !== 0) {
      return exitCode;
    }
  }

  return 0;
}

async function runPackageScript(
  task: ValidationTask,
): Promise<ValidationTaskResult> {
  const { npm_execpath: pnpmEntrypoint } = process.env;
  if (!pnpmEntrypoint) {
    return { task, exitCode: 127, signal: null };
  }

  const child = spawn(pnpmEntrypoint, ["run", task.script], {
    cwd: process.cwd(),
    env: process.env,
    stdio: "inherit",
  });

  return new Promise((resolve) => {
    child.once("error", () => {
      resolve({ task, exitCode: 127, signal: null });
    });
    child.once("exit", (exitCode, signal) => {
      resolve({ task, exitCode, signal });
    });
  });
}

function pnpmVersion(): string {
  const { npm_config_user_agent: userAgent } = process.env;
  return userAgent?.match(/pnpm\/([^\s]+)/)?.[1] ?? "unknown";
}

const entrypoint = process.argv[1];
if (entrypoint && pathToFileURL(entrypoint).href === import.meta.url) {
  process.exitCode = await runHomepageValidation();
}
