import { useEffect, useState } from "react";
import type { Arch } from "../types";

interface UADataValues {
  architecture?: string;
  bitness?: string;
}

interface UAData {
  getHighEntropyValues(hints: string[]): Promise<UADataValues>;
}

/**
 * Best-effort Apple silicon / Intel detection for the download picker.
 *
 * Chromium exposes `navigator.userAgentData.getHighEntropyValues()`, which
 * reports the real CPU architecture. Safari has no equivalent, so we fall
 * back to inspecting the WebGL renderer string. If neither works we leave
 * the choice open instead of guessing.
 */
function detectFromWebGL(): Arch | null {
  try {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl") as WebGLRenderingContext | null;
    if (!gl) return null;

    const debug = gl.getExtension("WEBGL_debug_renderer_info");
    const renderer = debug ? String(gl.getParameter(debug.UNMASKED_RENDERER_WEBGL)) : "";

    if (/Apple M\d|Apple GPU|Apple Silicon/i.test(renderer)) return "arm64";
    if (/Intel/i.test(renderer)) return "x86_64";
    return null;
  } catch {
    return null;
  }
}

export function usePlatform(): Arch | null {
  const [arch, setArch] = useState<Arch | null>(null);

  useEffect(() => {
    if (!/Mac/i.test(navigator.userAgent)) return;

    let cancelled = false;

    const settle = (value: Arch | null) => {
      if (!cancelled && value) setArch(value);
    };

    const uaData = (navigator as Navigator & { userAgentData?: UAData }).userAgentData;

    if (typeof uaData?.getHighEntropyValues === "function") {
      uaData
        .getHighEntropyValues(["architecture", "bitness"])
        .then((values) => {
          if (cancelled) return;
          const architecture = values.architecture ?? "";
          if (/arm/i.test(architecture)) {
            setArch("arm64");
            return;
          }
          if (/x86/i.test(architecture)) {
            setArch("x86_64");
            return;
          }
          settle(detectFromWebGL());
        })
        .catch(() => settle(detectFromWebGL()));
    } else {
      settle(detectFromWebGL());
    }

    return () => {
      cancelled = true;
    };
  }, []);

  return arch;
}
