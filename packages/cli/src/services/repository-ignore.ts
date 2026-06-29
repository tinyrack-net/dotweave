import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathExists, writeTextFileAtomically } from "#app/lib/filesystem.ts";

const gitIgnoreFileName = ".gitignore";
const beginMarker = "# BEGIN dotweave managed secret artifact rules";
const endMarker = "# END dotweave managed secret artifact rules";

export const managedSecretArtifactIgnoreBlock = `${beginMarker}
!profiles/
!profiles/**/
!profiles/**/*.dotweave.secret
${endMarker}
`;

const managedSecretArtifactIgnoreBlockPattern = new RegExp(
  `${beginMarker}[\\s\\S]*?${endMarker}\\n?`,
  "g",
);

export const ensureManagedSecretArtifactIgnoreRules = async (
  syncDirectory: string,
) => {
  const ignorePath = join(syncDirectory, gitIgnoreFileName);
  const existingContents = (await pathExists(ignorePath))
    ? await readFile(ignorePath, "utf8")
    : "";

  const withoutManagedBlock = existingContents.replace(
    managedSecretArtifactIgnoreBlockPattern,
    "",
  );
  const nextContents = `${withoutManagedBlock}${
    withoutManagedBlock === "" || withoutManagedBlock.endsWith("\n") ? "" : "\n"
  }${managedSecretArtifactIgnoreBlock}`;

  if (nextContents === existingContents) {
    return;
  }

  await writeTextFileAtomically(ignorePath, nextContents);
};
