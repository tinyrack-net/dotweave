// Transcribed from a real session and cross-checked against the command
// reference pages, so the hero never drifts from what the CLI actually prints.
// Output stays English in every locale, matching the install tab labels.
export const terminalSteps = [
  "❯ dotweave track ~/.gitconfig\n✔ Started tracking .gitconfig\n  kind  file\n  path  /home/you/.gitconfig\n  repo  .gitconfig\n  mode  normal",
  "❯ dotweave push\n✔ Push complete\n  plain: 2\n  encrypted: 1\n  symlinks: 0\n  dirs: 1",
  "❯ dotweave pull\n✔ Pull complete\n  updated: 1 paths updated\n  removed: 0 paths removed",
] as const;

export const installTargets = [
  {
    command: "winget install tinyrack.dotweave",
    label: "Windows",
    value: "winget",
  },
  {
    command: "brew install tinyrack-net/tap/dotweave",
    label: "macOS / Linux",
    value: "homebrew",
  },
] as const;
