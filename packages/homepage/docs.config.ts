import { readFileSync } from "node:fs";

import { defineDocsConfig } from "@tinyrack/docs/config";

const cliPackage = JSON.parse(
  readFileSync(new URL("../cli/package.json", import.meta.url), "utf8"),
) as { version: string };

const labels = (en: string, ko: string, ja: string) => ({ en, ja, ko });

export default defineDocsConfig({
  contentDir: "app/content",
  header: {
    links: [
      {
        label: "GitHub",
        path: "https://github.com/tinyrack-net/dotweave",
      },
    ],
    version: cliPackage.version,
  },
  i18n: {
    defaultLocale: "en",
    locales: {
      en: { label: "English", language: "en", openGraph: "en_US" },
      ko: { label: "한국어", language: "ko", openGraph: "ko_KR" },
      ja: { label: "日本語", language: "ja", openGraph: "ja_JP" },
    },
  },
  navigation: [
    {
      type: "group",
      label: labels("Overview", "시작하기", "はじめに"),
      children: [
        { type: "page", contentKey: "/intro" },
        { type: "page", contentKey: "/getting-started" },
      ],
    },
    {
      type: "group",
      label: labels("Guides", "가이드", "ガイド"),
      children: [
        "directory-structure",
        "tracking-files",
        "sync-modes",
        "syncing-secrets",
        "profiles",
        "platform-specific-paths",
        "multi-device-workflow",
        "how-it-works",
        "shell-autocomplete",
      ].map((slug) => ({
        type: "page" as const,
        contentKey: `/guides/${slug}`,
      })),
    },
    {
      type: "group",
      label: labels(
        "Command Reference",
        "명령어 레퍼런스",
        "コマンドリファレンス",
      ),
      children: [
        "init",
        "track",
        "push",
        "pull",
        "status",
        "untrack",
        "cd",
        "profile",
        "doctor",
        "autocomplete",
      ].map((slug) => ({
        type: "page" as const,
        contentKey: `/reference/${slug}`,
      })),
    },
  ],
  redirects: { "/": "/en/" },
  sections: [
    {
      id: "overview",
      label: labels("Overview", "시작하기", "はじめに"),
      order: 0,
    },
    { id: "guides", label: labels("Guides", "가이드", "ガイド"), order: 1 },
    {
      id: "reference",
      label: labels(
        "Command Reference",
        "명령어 레퍼런스",
        "コマンドリファレンス",
      ),
      order: 2,
    },
  ],
  site: {
    basePath: "/",
    description:
      "Git-backed configuration sync for your development environment.",
    favicon: "/favicon.svg",
    locale: { language: "en", openGraph: "en_US" },
    logo: { alt: "Dotweave", dark: "/logo.svg", light: "/logo.svg" },
    title: "Dotweave",
    url: "https://dotweave.tinyrack.net",
  },
  theme: { default: "dark" },
});
