import createGlobe from "cobe";
import { useEffect, useRef } from "react";

type Globe = ReturnType<typeof createGlobe>;
type GlobeFactory = (
  canvas: HTMLCanvasElement,
  options: Parameters<typeof createGlobe>[1],
) => Globe;

const locations: [number, number][] = [
  [37.56, 126.97],
  [35.68, 139.69],
  [37.77, -122.42],
  [51.51, -0.13],
  [52.52, 13.41],
  [-33.87, 151.21],
  [1.35, 103.82],
  [49.28, -123.12],
];
const repositoryHub: [number, number] = [30, -30];
const teal: [number, number, number] = [0.18, 0.83, 0.75];
const colors: [number, number, number][] = [
  teal,
  [0.22, 0.74, 0.97],
  [0.2, 0.83, 0.6],
];

export function mountDotweaveGlobe(
  canvas: HTMLCanvasElement,
  container: HTMLElement,
  create: GlobeFactory = createGlobe,
) {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let frameId: number | undefined;
  let globe: Globe | undefined;
  let phi = 0;
  let disposed = false;

  function stopCurrentGlobe() {
    if (frameId !== undefined) cancelAnimationFrame(frameId);
    frameId = undefined;
    globe?.destroy();
    globe = undefined;
  }

  function setup() {
    if (disposed) return;
    stopCurrentGlobe();

    const rect = container.getBoundingClientRect();
    const size = Math.max(rect.width, rect.height, 700);
    const dpr = Math.min(window.devicePixelRatio, 2);
    const isDark =
      document.documentElement.getAttribute("data-theme") !== "tinyrack-light";
    const arcs = locations.flatMap((location, index) => [
      {
        color: colors[index % colors.length] ?? teal,
        from: location,
        to: repositoryHub,
      },
      {
        color: colors[(index + 1) % colors.length] ?? teal,
        from: repositoryHub,
        to: location,
      },
    ]);

    canvas.width = Math.round(size * dpr);
    canvas.height = Math.round(size * dpr);
    canvas.style.width = `${size}px`;
    canvas.style.height = `${size}px`;

    globe = create(canvas, {
      arcColor: teal,
      arcHeight: 0.3,
      arcs,
      arcWidth: 0.5,
      baseColor: isDark ? [0.08, 0.1, 0.14] : [0.88, 0.9, 0.92],
      dark: isDark ? 1 : 0,
      devicePixelRatio: dpr,
      diffuse: isDark ? 1.4 : 1.8,
      glowColor: isDark ? [0.04, 0.15, 0.15] : [0.82, 0.92, 0.92],
      height: size * dpr,
      mapBrightness: isDark ? 3 : 6,
      mapSamples: 20_000,
      markerColor: teal,
      markers: [
        { location: repositoryHub, size: 0.15 },
        ...locations.map((location) => ({ location, size: 0.04 })),
      ],
      offset: [0, 0],
      opacity: isDark ? 0.95 : 0.9,
      phi,
      scale: 1.1,
      theta: 0.15,
      width: size * dpr,
    });

    if (reducedMotion.matches) return;
    const animate = () => {
      phi += 0.002;
      globe?.update({ phi });
      frameId = requestAnimationFrame(animate);
    };
    frameId = requestAnimationFrame(animate);
  }

  const resizeObserver = new ResizeObserver(setup);
  resizeObserver.observe(container);
  const themeObserver = new MutationObserver((records) => {
    if (records.some((record) => record.attributeName === "data-theme"))
      setup();
  });
  themeObserver.observe(document.documentElement, {
    attributeFilter: ["data-theme"],
    attributes: true,
  });
  reducedMotion.addEventListener("change", setup);
  setup();

  return () => {
    disposed = true;
    resizeObserver.disconnect();
    themeObserver.disconnect();
    reducedMotion.removeEventListener("change", setup);
    stopCurrentGlobe();
  };
}

export function GlobeBackground() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (canvasRef.current === null || containerRef.current === null) return;
    return mountDotweaveGlobe(canvasRef.current, containerRef.current);
  }, []);

  return (
    <div aria-hidden="true" className="dotweave-globe" ref={containerRef}>
      <canvas ref={canvasRef} />
    </div>
  );
}
