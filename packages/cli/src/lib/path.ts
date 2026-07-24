import { realpathSync } from "node:fs";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";

const homePrefix = "~";
const posixPathSeparator = "/";

export const homeSymbol = homePrefix;
export const pathSeparator = posixPathSeparator;

export const buildDirectoryKey = (repoPath: string) => {
  return `${repoPath}/`;
};

export const isPathEqualOrNested = (path: string, rootPath: string) => {
  const rootToPath = relative(rootPath, path);

  return (
    rootToPath === "" ||
    (!isAbsolute(rootToPath) &&
      !rootToPath.startsWith("..") &&
      rootToPath !== "..")
  );
};

export const doPathsOverlap = (leftPath: string, rightPath: string) => {
  return (
    isPathEqualOrNested(leftPath, rightPath) ||
    isPathEqualOrNested(rightPath, leftPath)
  );
};

export const isExplicitLocalPath = (target: string) => {
  const homePathPrefix = `${homePrefix}${posixPathSeparator}`;

  return (
    target === "." ||
    target === ".." ||
    target === homePrefix ||
    target.startsWith("./") ||
    target.startsWith("../") ||
    target.startsWith(homePathPrefix) ||
    isAbsolute(target)
  );
};

/**
 * @description
 * Canonicalizes a symlink target for portable repository storage and comparison
 * by converting Windows backslash separators to POSIX forward slashes. The
 * relative/absolute nature of the target is preserved verbatim.
 */
export const toPosixLinkTarget = (target: string) => {
  return target.replaceAll("\\", "/");
};

/**
 * @description
 * Converts a POSIX-normalized symlink target back to the native separator for
 * the current platform when materializing an OS link. Only Windows needs the
 * conversion; POSIX platforms keep forward slashes.
 */
export const toNativeLinkTarget = (
  target: string,
  platform: NodeJS.Platform = process.platform,
) => {
  return platform === "win32" ? target.replaceAll("/", "\\") : target;
};

export type LinkTargetNormalizerPlatform = NodeJS.Platform;

interface NormalizeLinkTargetDependencies {
  platform?: LinkTargetNormalizerPlatform;
  realpathSyncNative?: (path: string) => string;
  resolvePath?: (...paths: string[]) => string;
  dirnamePath?: (path: string) => string;
  basenamePath?: (path: string) => string;
  joinPath?: (...paths: string[]) => string;
  isAbsolutePath?: (path: string) => boolean;
}

export const normalizeLinkTargetWithDependencies = (
  target: string,
  baseDir: string | undefined,
  deps: NormalizeLinkTargetDependencies = {},
) => {
  const platform = deps.platform ?? process.platform;
  const realpathSyncNative = deps.realpathSyncNative ?? realpathSync.native;
  const resolvePath = deps.resolvePath ?? resolve;
  const dirnamePath = deps.dirnamePath ?? dirname;
  const basenamePath = deps.basenamePath ?? basename;
  const joinPath = deps.joinPath ?? join;
  const isAbsolutePath = deps.isAbsolutePath ?? isAbsolute;

  const absoluteTarget =
    baseDir !== undefined && !isAbsolutePath(target)
      ? resolvePath(baseDir, target)
      : target;

  if (platform !== "win32") {
    return absoluteTarget;
  }

  const normalizeSlashes = (p: string) => p.replaceAll("\\", "/").toLowerCase();

  const resolveIfWindowsRootRelative = (p: string) => {
    if (p.startsWith("\\") && !p.startsWith("\\\\")) {
      return resolvePath(p);
    }
    return p;
  };

  try {
    return normalizeSlashes(realpathSyncNative(absoluteTarget));
  } catch {
    if (baseDir !== undefined) {
      try {
        const dir = dirnamePath(absoluteTarget);
        const base = basenamePath(absoluteTarget);
        return normalizeSlashes(joinPath(realpathSyncNative(dir), base));
      } catch {
        return normalizeSlashes(resolveIfWindowsRootRelative(absoluteTarget));
      }
    }

    return normalizeSlashes(resolveIfWindowsRootRelative(absoluteTarget));
  }
};

export const normalizeLinkTarget = (target: string, baseDir?: string) => {
  return normalizeLinkTargetWithDependencies(target, baseDir);
};
