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
      ko: {
        label: "한국어",
        language: "ko",
        openGraph: "ko_KR",
        messages: {
          closeNavigation: "탐색 닫기",
          closeSearch: "검색 닫기",
          emptySearch: "문서를 찾지 못했어요.",
          language: "언어",
          loading: "페이지 불러오는 중",
          navigation: "문서",
          navigationSidebar: "문서 사이드바",
          next: "다음",
          nextDocument: "다음 문서",
          onThisPage: "이 페이지에서",
          openNavigation: "탐색 열기",
          previous: "이전",
          previousDocument: "이전 문서",
          search: "문서 검색",
          searchFallback: "번들된 대체 검색 인덱스를 사용 중입니다.",
          searchIdle: "검색어를 입력하세요.",
          searchLoading: "문서 검색 중",
          searchResults: "검색 결과",
        },
      },
      ja: {
        label: "日本語",
        language: "ja",
        openGraph: "ja_JP",
        messages: {
          closeNavigation: "ナビゲーションを閉じる",
          closeSearch: "検索を閉じる",
          emptySearch: "ドキュメントが見つかりません。",
          language: "言語",
          loading: "ページを読み込み中",
          navigation: "ドキュメント",
          navigationSidebar: "ドキュメントサイドバー",
          next: "次へ",
          nextDocument: "次のドキュメント",
          onThisPage: "このページ",
          openNavigation: "ナビゲーションを開く",
          previous: "前へ",
          previousDocument: "前のドキュメント",
          search: "ドキュメントを検索",
          searchFallback: "組み込みの代替検索インデックスを使用しています。",
          searchIdle: "検索語を入力してください。",
          searchLoading: "ドキュメントを検索中",
          searchResults: "検索結果",
        },
      },
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
    { id: "overview", label: "Overview", order: 0 },
    { id: "guides", label: "Guides", order: 1 },
    { id: "reference", label: "Command Reference", order: 2 },
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
