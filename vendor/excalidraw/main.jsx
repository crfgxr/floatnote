// FloatNote ↔ Excalidraw bridge entry.
// Bundled by build.mjs into a single self-contained file (React + Excalidraw +
// all deps) so it runs fully offline inside a WKWebView. No network at runtime.

import React, { useEffect, useRef, useState, useCallback } from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, restore } from "@excalidraw/excalidraw";

// Fonts and worker assets are copied next to this bundle; tell Excalidraw where.
// Set before the component mounts so font loading resolves locally.
window.EXCALIDRAW_ASSET_PATH = "./";

// Post a message to the Swift side. No-op in a plain browser (used for local
// testing of the HTML without the native host).
function toSwift(payload) {
  try {
    window.webkit?.messageHandlers?.floatnote?.postMessage(payload);
  } catch (e) {
    // ignore — not running inside the native host
  }
}

function debounce(fn, ms) {
  let t = null;
  const wrapped = (...args) => {
    if (t) clearTimeout(t);
    t = setTimeout(() => {
      t = null;
      fn(...args);
    }, ms);
  };
  wrapped.flush = (...args) => {
    if (t) {
      clearTimeout(t);
      t = null;
    }
    fn(...args);
  };
  return wrapped;
}

function App() {
  const apiRef = useRef(null);
  // The board owns its theme. It used to be driven from the app's palette, which
  // meant a dark app forced a dark canvas — and Excalidraw's dark mode inverts
  // every embedded image (invert(93%) hue-rotate(180deg)), so pasted screenshots
  // came back near-black. A new board starts light, the Theme control in
  // Preferences switches it, and the choice is saved with the scene.
  const [theme, setTheme] = useState("light");
  const themeRef = useRef("light");

  const setBoardTheme = (next) => {
    const t = next === "dark" ? "dark" : "light";
    if (themeRef.current === t) return;
    themeRef.current = t;
    setTheme(t);
  };

  // Debounced save back to Swift.
  const save = useRef(
    debounce((api) => {
      if (!api) return;
      const elements = api.getSceneElements();
      const appState = api.getAppState();
      const files = api.getFiles();
      toSwift({
        type: "save",
        elements,
        appState: {
          viewBackgroundColor: appState.viewBackgroundColor,
          gridSize: appState.gridSize,
          theme: appState.theme,
        },
        files,
      });
    }, 800)
  ).current;

  // `theme` is a controlled prop, so Excalidraw's own toggle only sticks if the
  // host follows the appState it just wrote.
  const onChange = useCallback((elements, appState) => {
    if (appState && appState.theme) setBoardTheme(appState.theme);
    save(apiRef.current);
  }, [save]);

  // Expose imperative hooks for the native host.
  useEffect(() => {
    window.floatnoteLoadScene = (raw) => {
      const api = apiRef.current;
      if (!api) return;
      let data = raw;
      if (typeof raw === "string") {
        try {
          data = JSON.parse(raw);
        } catch (e) {
          data = {};
        }
      }
      data = data || {};
      const restored = restore(
        { elements: data.elements || [], appState: data.appState || {}, files: data.files || {} },
        null,
        null
      );
      if (restored.files && Object.keys(restored.files).length) {
        api.addFiles(Object.values(restored.files));
      }
      if (restored.appState && restored.appState.theme) setBoardTheme(restored.appState.theme);
      api.updateScene({ elements: restored.elements, appState: restored.appState });
      api.scrollToContent(restored.elements, { fitToContent: true });
    };

    // Kept for the native bridge, deliberately inert: the app's palette no
    // longer decides how the canvas is painted (see the note on `theme`).
    window.floatnoteSetTheme = () => {};

    // Flush any pending save immediately (called before teardown / tab switch).
    window.floatnoteFlush = () => {
      save.flush(apiRef.current);
    };

    return () => {
      delete window.floatnoteLoadScene;
      delete window.floatnoteSetTheme;
      delete window.floatnoteFlush;
    };
  }, [save]);

  return React.createElement(Excalidraw, {
    excalidrawAPI: (api) => {
      apiRef.current = api;
      // Page is mounted and the API is live — ask Swift for the initial scene.
      toSwift({ type: "ready" });
    },
    onChange,
    theme,
    UIOptions: {
      canvasActions: {
        loadScene: false,
        saveToActiveFile: false,
        export: false,
        saveAsImage: true,
        // Excalidraw hides its Theme control whenever the host passes `theme`;
        // this puts it back in Preferences, where it lives upstream.
        toggleTheme: true,
      },
    },
  });
}

const root = createRoot(document.getElementById("root"));
root.render(React.createElement(App));
