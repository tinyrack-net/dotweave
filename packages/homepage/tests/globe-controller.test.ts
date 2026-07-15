import { afterEach, describe, expect, it, vi } from "vitest";

import { mountDotweaveGlobe } from "../app/components/globe-background.tsx";

type ObserverCallback = (records?: MutationRecord[]) => void;

function installBrowserFakes(reducedMotion = false) {
  const raf = vi.fn(() => 7);
  const cancelRaf = vi.fn();
  const mediaListeners = new Set<() => void>();
  const media = {
    matches: reducedMotion,
    addEventListener: vi.fn((_type: string, listener: () => void) => {
      mediaListeners.add(listener);
    }),
    removeEventListener: vi.fn((_type: string, listener: () => void) => {
      mediaListeners.delete(listener);
    }),
  };
  const resizeObservers: ObserverCallback[] = [];
  const mutationObservers: ObserverCallback[] = [];

  class ResizeObserverFake {
    callback: ObserverCallback;
    disconnect = vi.fn();
    observe = vi.fn();

    constructor(callback: ObserverCallback) {
      this.callback = callback;
      resizeObservers.push(callback);
    }
  }

  class MutationObserverFake {
    callback: ObserverCallback;
    disconnect = vi.fn();
    observe = vi.fn();

    constructor(callback: ObserverCallback) {
      this.callback = callback;
      mutationObservers.push(callback);
    }
  }

  vi.stubGlobal("requestAnimationFrame", raf);
  vi.stubGlobal("cancelAnimationFrame", cancelRaf);
  vi.stubGlobal("ResizeObserver", ResizeObserverFake);
  vi.stubGlobal("MutationObserver", MutationObserverFake);
  vi.stubGlobal("window", {
    devicePixelRatio: 2,
    matchMedia: vi.fn(() => media),
  });
  vi.stubGlobal("document", {
    documentElement: {
      getAttribute: vi.fn((name: string) =>
        name === "data-theme" ? "tinyrack-dark" : null,
      ),
    },
  });

  return {
    cancelRaf,
    media,
    mediaListeners,
    mutationObservers,
    raf,
    resizeObservers,
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Dotweave globe lifecycle", () => {
  it("recreates on resize and theme changes, then releases every resource", () => {
    const browser = installBrowserFakes();
    const globes: Array<{
      destroy: ReturnType<typeof vi.fn>;
      update: ReturnType<typeof vi.fn>;
    }> = [];
    const createGlobe = vi.fn(() => {
      const globe = { destroy: vi.fn(), update: vi.fn() };
      globes.push(globe);
      return globe;
    });
    const canvas = { height: 0, style: {}, width: 0 } as HTMLCanvasElement;
    const container = {
      getBoundingClientRect: () => ({ height: 720, width: 960 }),
    } as HTMLElement;

    const dispose = mountDotweaveGlobe(canvas, container, createGlobe);
    browser.resizeObservers[0]?.();
    browser.mutationObservers[0]?.([
      { attributeName: "data-theme" } as MutationRecord,
    ]);

    expect(createGlobe).toHaveBeenCalledTimes(3);
    expect(browser.raf).toHaveBeenCalled();

    dispose();

    expect(browser.cancelRaf).toHaveBeenCalled();
    expect(browser.media.removeEventListener).toHaveBeenCalled();
    expect(globes.every((globe) => globe.destroy.mock.calls.length > 0)).toBe(
      true,
    );
  });

  it("renders a static globe when reduced motion is requested", () => {
    const browser = installBrowserFakes(true);
    const createGlobe = vi.fn(() => ({ destroy: vi.fn(), update: vi.fn() }));
    const canvas = { height: 0, style: {}, width: 0 } as HTMLCanvasElement;
    const container = {
      getBoundingClientRect: () => ({ height: 600, width: 800 }),
    } as HTMLElement;

    const dispose = mountDotweaveGlobe(canvas, container, createGlobe);

    expect(createGlobe).toHaveBeenCalledOnce();
    expect(browser.raf).not.toHaveBeenCalled();
    dispose();
  });
});
