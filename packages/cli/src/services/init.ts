import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AppConstants } from "#app/config/constants.ts";
import {
  formatGlobalDotweaveConfig,
  type GlobalDotweaveConfig,
  readGlobalDotweaveConfig,
} from "#app/config/global-config.ts";
import { resolveDefaultIdentityFile } from "#app/config/identity-file.ts";
import { resolveDotweaveHomeDirectoryFromEnv } from "#app/config/runtime-env.ts";
import {
  createInitialSyncConfig,
  formatSyncConfig,
  parseSyncConfig,
  readSyncConfig,
} from "#app/config/sync-schema.ts";
import {
  createAgeIdentityFile,
  readAgeRecipientsFromIdentityFile,
  writeAgeIdentityFile,
} from "#app/lib/crypto.ts";
import { DotweaveError, wrapUnknownError } from "#app/lib/error.ts";
import { pathExists, writeTextFileAtomically } from "#app/lib/filesystem.ts";
import {
  initializeRepository,
  isMissingGitExecutableError,
  verifyIsGitRepository,
} from "#app/lib/git.ts";
import { validateJsoncConfigPath } from "#app/lib/jsonc.ts";
import { ensureManagedSecretArtifactIgnoreRules } from "./repository-ignore.ts";
import {
  resolveAgeFromSyncConfig,
  resolveSyncConfigResolutionContext,
  resolveSyncPaths,
} from "./sync-context.ts";

export type InitRequest = Readonly<{
  ageIdentity?: string;
  force?: boolean;
  generateAgeIdentity?: boolean;
  identityFile?: string;
  recipients: readonly string[];
  repository?: string;
}>;

export type InitResult = Readonly<{
  alreadyInitialized: boolean;
  entryCount: number;
  gitAction: "cloned" | "existing" | "initialized";
  gitSource?: string;
  identityFile: string;
  generatedIdentity: boolean;
  recipientCount: number;
}>;

const gitAttributesFileName = ".gitattributes";
const gitAttributesContents = "* -text\n";

export const createMissingRepositoryAgeKeyError = () => {
  return new DotweaveError(
    "Existing repository setup requires an age private key.",
    {
      code: "INIT_AGE_IDENTITY_REQUIRED",
      hint: "Provide your existing age private key with '--key-file', or enter it when prompted in an interactive terminal.",
    },
  );
};

export const createAlreadyInitializedError = (syncDirectory: string) => {
  return new DotweaveError("Sync directory is already initialized.", {
    code: "INIT_ALREADY_INITIALIZED",
    details: [`Sync directory: ${syncDirectory}`],
    hint: "Use 'dotweave init --force' to replace the local sync repository data.",
  });
};

const normalizeRecipients = (recipients: readonly string[]) => {
  return [
    ...new Set(recipients.map((recipient) => recipient.trim()).filter(Boolean)),
  ].sort((left, right) => {
    return left.localeCompare(right);
  });
};

const resolveInitAgeBootstrap = async (request: InitRequest) => {
  const identityFile = resolveDefaultIdentityFile(
    resolveDotweaveHomeDirectoryFromEnv(),
  );
  const explicitRecipients = normalizeRecipients(request.recipients);

  if (request.ageIdentity !== undefined) {
    const { recipient } = await writeAgeIdentityFile(
      identityFile,
      request.ageIdentity,
    );

    return {
      generatedIdentity: false,
      recipients: normalizeRecipients([...explicitRecipients, recipient]),
    };
  }

  if (explicitRecipients.length === 0) {
    if (await pathExists(identityFile)) {
      return {
        generatedIdentity: false,
        recipients: normalizeRecipients(
          await readAgeRecipientsFromIdentityFile(identityFile),
        ),
      };
    }

    const { recipient } = await createAgeIdentityFile(identityFile);

    return {
      generatedIdentity: true,
      recipients: [recipient],
    };
  }

  if (request.generateAgeIdentity === true) {
    const { recipient } = await createAgeIdentityFile(identityFile);

    return {
      generatedIdentity: true,
      recipients: normalizeRecipients([...explicitRecipients, recipient]),
    };
  }

  if (await pathExists(identityFile)) {
    return {
      generatedIdentity: false,
      recipients: explicitRecipients,
    };
  }

  const { recipient } = await createAgeIdentityFile(identityFile);

  return {
    generatedIdentity: true,
    recipients: normalizeRecipients([...explicitRecipients, recipient]),
  };
};

const writeGlobalSettings = async (globalConfigPath: string) => {
  const existingGlobalConfig = await readGlobalDotweaveConfig(globalConfigPath);
  const globalConfigToWrite: GlobalDotweaveConfig = {
    activeProfile:
      existingGlobalConfig?.activeProfile ?? AppConstants.SYNC.DEFAULT_PROFILE,
    version: AppConstants.GLOBAL_CONFIG.CURRENT_VERSION,
  };
  await mkdir(dirname(globalConfigPath), { recursive: true });
  await writeTextFileAtomically(
    globalConfigPath,
    formatGlobalDotweaveConfig(globalConfigToWrite),
  );
};

const ensureManagedRepositoryAttributes = async (syncDirectory: string) => {
  const attributesPath = join(syncDirectory, gitAttributesFileName);

  if (await pathExists(attributesPath)) {
    const existingContents = await readFile(attributesPath, "utf8");

    if (existingContents === gitAttributesContents) {
      return;
    }
  }

  await writeTextFileAtomically(attributesPath, gitAttributesContents);
};

export const initializeSyncDirectory = async (
  request: InitRequest,
): Promise<InitResult> => {
  const { syncDirectory, configPath, globalConfigPath } = resolveSyncPaths();
  const context = resolveSyncConfigResolutionContext();
  const identityFile = resolveDefaultIdentityFile(
    resolveDotweaveHomeDirectoryFromEnv(),
  );

  if (request.force === true) {
    await rm(syncDirectory, { force: true, recursive: true });
    await rm(identityFile, { force: true });
    await rm(globalConfigPath, { force: true });
  }

  const resolvedConfigPath = await validateJsoncConfigPath(configPath);
  const configExists = await pathExists(resolvedConfigPath);
  const importingRepository =
    request.repository !== undefined && request.repository.trim() !== "";

  if (
    importingRepository &&
    request.ageIdentity === undefined &&
    !(await pathExists(identityFile))
  ) {
    throw createMissingRepositoryAgeKeyError();
  }

  if (configExists) {
    throw createAlreadyInitializedError(syncDirectory);
  }

  await mkdir(dirname(syncDirectory), {
    recursive: true,
  });

  let gitAction: InitResult["gitAction"] = "existing";
  let gitSource: string | undefined;

  try {
    await verifyIsGitRepository(syncDirectory);
  } catch {
    const syncDirectoryExists = await pathExists(syncDirectory);

    if (syncDirectoryExists) {
      const entries = await readdir(syncDirectory);

      if (entries.length > 0) {
        throw new DotweaveError(
          "Sync directory already exists and is not empty.",
          {
            code: "SYNC_DIR_NOT_EMPTY",
            details: [`Sync directory: ${syncDirectory}`],
            hint: "Empty the directory, remove it, or point init at a different repository source.",
          },
        );
      }
    }

    const gitSourceInput = request.repository?.trim() || undefined;
    let gitResult: Awaited<ReturnType<typeof initializeRepository>>;

    try {
      gitResult = await initializeRepository(syncDirectory, gitSourceInput);
    } catch (error: unknown) {
      const errorMessage =
        gitSourceInput === undefined
          ? "Failed to initialize the sync directory."
          : "Failed to clone the sync directory.";
      const errorCode =
        gitSourceInput === undefined
          ? "SYNC_INIT_GIT_FAILED"
          : "SYNC_CLONE_FAILED";
      const details = [
        `Sync directory: ${syncDirectory}`,
        ...(gitSourceInput === undefined
          ? []
          : [`Repository source: ${gitSourceInput}`]),
      ];

      if (isMissingGitExecutableError(error)) {
        throw new DotweaveError(errorMessage, {
          code: errorCode,
          details: [
            ...details,
            error instanceof Error
              ? error.message
              : "Git is not installed or not on PATH.",
          ],
          hint: "Install Git and ensure the git executable is available on PATH, then run dotweave init again.",
        });
      }

      throw wrapUnknownError(errorMessage, error, {
        code: errorCode,
        details,
        hint:
          gitSourceInput === undefined
            ? "Check that git is installed and the sync directory is writable."
            : "Check that the repository source is reachable and you have access to it.",
      });
    }

    gitAction = gitResult.action;
    gitSource = gitResult.source;
  }

  await mkdir(syncDirectory, { recursive: true });
  await ensureManagedRepositoryAttributes(syncDirectory);
  await ensureManagedSecretArtifactIgnoreRules(syncDirectory);

  if (await pathExists(await validateJsoncConfigPath(configPath))) {
    const config = await readSyncConfig(syncDirectory, context);

    const ageBootstrap = await resolveInitAgeBootstrap(request);

    await writeGlobalSettings(globalConfigPath);

    const age =
      config.age !== undefined
        ? resolveAgeFromSyncConfig(config.age)
        : undefined;

    return {
      alreadyInitialized: false,
      entryCount: config.entries.length,
      gitAction,
      ...(gitSource === undefined ? {} : { gitSource }),
      generatedIdentity: ageBootstrap.generatedIdentity,
      identityFile:
        age?.identityFile ??
        resolveDefaultIdentityFile(resolveDotweaveHomeDirectoryFromEnv()),
      recipientCount: age?.recipients.length ?? 0,
    };
  }

  const ageBootstrap = await resolveInitAgeBootstrap(request);

  await writeGlobalSettings(globalConfigPath);

  const initialConfig = createInitialSyncConfig({
    recipients: [...new Set(ageBootstrap.recipients.map((r) => r.trim()))],
  });

  parseSyncConfig(initialConfig, context);
  await writeFile(configPath, formatSyncConfig(initialConfig), "utf8");

  return {
    alreadyInitialized: false,
    entryCount: 0,
    gitAction,
    ...(gitSource === undefined ? {} : { gitSource }),
    generatedIdentity: ageBootstrap.generatedIdentity,
    identityFile: resolveDefaultIdentityFile(
      resolveDotweaveHomeDirectoryFromEnv(),
    ),
    recipientCount: ageBootstrap.recipients.length,
  };
};
