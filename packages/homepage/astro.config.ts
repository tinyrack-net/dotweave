import { readFileSync } from "node:fs";
import starlight from "@astrojs/starlight";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";
import starlightThemeBlack from "starlight-theme-black";

const cliPackageJson = JSON.parse(
  readFileSync(new URL("../cli/package.json", import.meta.url), "utf8"),
);
const cliVersion = String(cliPackageJson.version);

export default defineConfig({
  site: "https://dotweave.tinyrack.net",
  trailingSlash: "always",
  redirects: {
    "/": "/en/",
  },
  server: {
    port: 5432,
    host: "0.0.0.0",
    allowedHosts: true,
  },
  vite: {
    build: {
      // lightningcss rejects some Starlight/Tailwind generated selectors on Vite 8.
      cssMinify: "esbuild",
    },
    server: {
      strictPort: true,
    },
    define: {
      __CLI_VERSION__: JSON.stringify(cliVersion),
    },
    plugins: [tailwindcss()],
  },
  integrations: [
    starlight({
      expressiveCode: {
        defaultProps: {
          frame: "none",
        },
      },
      title: "Dotweave",
      logo: {
        src: "./src/assets/logo.svg",
        alt: "Dotweave",
      },
      favicon: "/favicon.svg",
      description:
        "Git-backed configuration sync for your development environment.",
      head: [
        {
          tag: "meta",
          attrs: {
            name: "google-site-verification",
            content: "-4detF9HYfr_TzkI1CzY4aZS7DuiYM6wR7U9YY2-jKw",
          },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:card", content: "summary" },
        },
        {
          tag: "meta",
          attrs: { property: "og:site_name", content: "Dotweave" },
        },
      ],
      defaultLocale: "en",
      locales: {
        en: {
          label: "English",
          lang: "en",
        },
        ko: {
          label: "한국어",
          lang: "ko",
        },
        ja: {
          label: "日本語",
          lang: "ja",
        },
      },
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/tinyrack-net/dotweave",
        },
      ],
      plugins: [
        starlightThemeBlack({
          footerText:
            "Dotweave · MIT License · [GitHub](https://github.com/tinyrack-net/dotweave)",
        }),
      ],
      customCss: ["./src/styles/tailwind.css"],
      components: {
        Header: "./src/components/Header.astro",
        Hero: "./src/components/OverrideHero.astro",
      },
      sidebar: [
        {
          label: "Overview",
          translations: {
            ko: "시작하기",
            ja: "はじめに",
          },
          items: [{ slug: "intro" }, { slug: "getting-started" }],
        },
        {
          label: "Guides",
          translations: {
            ko: "가이드",
            ja: "ガイド",
          },
          items: [
            { slug: "guides/directory-structure" },
            { slug: "guides/tracking-files" },
            { slug: "guides/sync-modes" },
            { slug: "guides/syncing-secrets" },
            { slug: "guides/profiles" },
            { slug: "guides/platform-specific-paths" },
            { slug: "guides/multi-device-workflow" },
            { slug: "guides/how-it-works" },
            { slug: "guides/shell-autocomplete" },
          ],
        },
        {
          label: "Command Reference",
          translations: {
            ko: "명령어 레퍼런스",
            ja: "コマンドリファレンス",
          },
          items: [
            { slug: "reference/init" },
            { slug: "reference/track" },
            { slug: "reference/push" },
            { slug: "reference/pull" },
            { slug: "reference/status" },
            { slug: "reference/untrack" },
            { slug: "reference/cd" },
            { slug: "reference/profile" },
            { slug: "reference/doctor" },
            { slug: "reference/autocomplete" },
          ],
        },
      ],
    }),
  ],
});
