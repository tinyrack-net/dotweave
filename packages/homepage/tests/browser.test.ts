import { readFile, stat } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { extname, join, normalize } from "node:path";

import { type Browser, chromium } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const buildRoot = join(import.meta.dirname, "..", "build", "client");
let browser: Browser;
let origin: string;
let server: Server;
let simulateCloudflareBeacon = false;

const contentTypes: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

beforeAll(async () => {
  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      if (url.pathname === "/cdn-cgi/rum") {
        response.writeHead(204).end();
        return;
      }
      const requestPath = decodeURIComponent(url.pathname);
      const relativePath = requestPath.endsWith("/")
        ? `${requestPath.slice(1)}index.html`
        : requestPath.slice(1);
      const path = normalize(join(buildRoot, relativePath));
      if (!path.startsWith(normalize(buildRoot)))
        throw new Error("Invalid path");
      const file = (await stat(path)).isDirectory()
        ? join(path, "index.html")
        : path;
      let body = await readFile(file);
      if (extname(file) === ".html" && simulateCloudflareBeacon) {
        body = Buffer.from(
          body.toString("utf8").replace(
            "</body>",
            `<script defer src="https://static.cloudflareinsights.com/beacon.min.js/v4513226cdae34746b4dedf0b4dfa099e1781791509496" data-cf-beacon='{"version":"2024.11.0","token":"test-token","r":1}' crossorigin="anonymous"></script>
</body>`,
          ),
        );
      }
      response.writeHead(200, {
        "content-type":
          contentTypes[extname(file)] ?? "application/octet-stream",
      });
      response.end(body);
    } catch {
      response.writeHead(404).end("Not found");
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string")
    throw new Error("No server port");
  origin = `http://127.0.0.1:${address.port}`;
  browser = await chromium.launch();
});

afterAll(async () => {
  await browser?.close();
  await new Promise<void>((resolve, reject) =>
    server?.close((error) => (error ? reject(error) : resolve())),
  );
});

describe("Dotweave built documentation", () => {
  it("protects hydration from Cloudflare analytics injection", async () => {
    const page = await browser.newPage();
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));

    simulateCloudflareBeacon = true;
    try {
      const response = await page.goto(
        `${origin}/en/guides/directory-structure/`,
      );
      expect(await response?.text()).toContain("data-cf-beacon");
      await page.locator('html[data-hydrated="true"]').waitFor();

      await expect(
        page.locator("script[data-cf-beacon]").count(),
      ).resolves.toBe(1);
      expect(errors).toEqual([]);
    } finally {
      simulateCloudflareBeacon = false;
      await page.close();
    }
  });

  it("renders the English landing and guide in desktop light mode", async () => {
    const page = await browser.newPage({ colorScheme: "light" });
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    await page.addInitScript(() =>
      localStorage.setItem("tinyrack-theme", "tinyrack-light"),
    );

    await page.goto(`${origin}/en/`);
    await page.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      page.getByRole("heading", { name: "Your config, anywhere." }).isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByText("Dotweave v0.52.0").first().isVisible(),
    ).resolves.toBe(true);
    expect(await page.locator("html").getAttribute("data-theme")).toBe(
      "tinyrack-light",
    );

    await page.goto(`${origin}/en/guides/directory-structure/`);
    await page.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      page.getByRole("heading", { name: "Directory Structure" }).isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByText("repository/", { exact: true }).first().isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.locator('meta[property="og:site_name"]').count(),
    ).resolves.toBe(1);
    await expect(
      page.locator('meta[name="twitter:card"]').getAttribute("content"),
    ).resolves.toBe("summary_large_image");
    expect(errors).toEqual([]);
    await page.close();
  });

  it("renders localized interactive docs in mobile dark mode", async () => {
    const page = await browser.newPage({
      colorScheme: "dark",
      reducedMotion: "reduce",
      viewport: { height: 844, width: 390 },
    });
    await page.addInitScript(() =>
      localStorage.setItem("tinyrack-theme", "tinyrack-dark"),
    );
    await page.goto(`${origin}/ko/getting-started/`);
    await page.locator('html[data-hydrated="true"]').waitFor();

    await expect(
      page.getByRole("heading", { exact: true, name: "시작하기" }).isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByRole("tab", { name: "Windows" }).isVisible(),
    ).resolves.toBe(true);
    expect(await page.locator("html").getAttribute("data-theme")).toBe(
      "tinyrack-dark",
    );
    await page.close();
  });

  it("keeps the root redirect", async () => {
    const page = await browser.newPage();
    await page.goto(`${origin}/`);
    await page.waitForURL(`${origin}/en/`);
    await page.close();
  });
});
