import { defineDocsConfig } from "@tinyrack/docs/config";

const labels = (en: string, ko: string, ja: string) => ({ en, ja, ko });

/** Guides that became concept pages. Keep the old URLs working. */
const movedGuides = Object.fromEntries(
  ["en", "ko", "ja"].flatMap((locale) =>
    Object.entries({
      "directory-structure": "repository-layout",
      "how-it-works": "how-it-works",
      "platform-specific-paths": "platform-paths",
      profiles: "profiles",
      "sync-modes": "sync-modes",
      "syncing-secrets": "secrets",
    }).map(([from, to]) => [
      `/${locale}/guides/${from}`,
      `/${locale}/concepts/${to}`,
    ]),
  ),
);

export default defineDocsConfig({
  contentDir: "app/content",
  header: {
    links: [
      {
        label: labels("Docs", "문서", "ドキュメント"),
        path: "/{locale}/intro/",
      },
      {
        label: "GitHub",
        path: "https://github.com/tinyrack-net/dotweave",
      },
    ],
    title: true,
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
      label: labels("Overview", "개요", "概要"),
      children: [
        { type: "page", contentKey: "/intro" },
        { type: "page", contentKey: "/install" },
        { type: "page", contentKey: "/getting-started" },
        { type: "page", contentKey: "/second-device" },
      ],
    },
    {
      type: "group",
      label: labels("Concepts", "개념", "コンセプト"),
      children: [
        "how-it-works",
        "repository-layout",
        "sync-modes",
        "profiles",
        "platform-paths",
        "secrets",
      ].map((slug) => ({
        type: "page" as const,
        contentKey: `/concepts/${slug}`,
      })),
    },
    {
      type: "group",
      label: labels("Guides", "가이드", "ガイド"),
      children: [
        "tracking-files",
        "daily-workflow",
        "multi-device-workflow",
        "shell-autocomplete",
        "agent-skill",
        "upgrading",
        "troubleshooting",
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
        "skill",
      ].map((slug) => ({
        type: "page" as const,
        contentKey: `/reference/${slug}`,
      })),
    },
    {
      type: "group",
      label: labels("Configuration", "설정 레퍼런스", "設定リファレンス"),
      children: ["manifest", "settings", "environment", "errors"].map(
        (slug) => ({
          type: "page" as const,
          contentKey: `/config/${slug}`,
        }),
      ),
    },
  ],
  redirects: { "/": "/en/", ...movedGuides },
  sections: [
    {
      id: "overview",
      label: labels("Overview", "개요", "概要"),
      order: 0,
    },
    {
      id: "concepts",
      label: labels("Concepts", "개념", "コンセプト"),
      order: 1,
    },
    { id: "guides", label: labels("Guides", "가이드", "ガイド"), order: 2 },
    {
      id: "reference",
      label: labels(
        "Command Reference",
        "명령어 레퍼런스",
        "コマンドリファレンス",
      ),
      order: 3,
    },
    {
      id: "config",
      label: labels("Configuration", "설정 레퍼런스", "設定リファレンス"),
      order: 4,
    },
  ],
  site: {
    basePath: "/",
    description:
      "Git-backed configuration sync for your development environment.",
    favicon: "/favicon.svg",
    locale: { language: "en", openGraph: "en_US" },
    logo: { alt: "Dotweave", dark: "/favicon.svg", light: "/favicon.svg" },
    title: "Dotweave",
    url: "https://dotweave.tinyrack.net",
  },
  theme: { default: "dark" },
});
