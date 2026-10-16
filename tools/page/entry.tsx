import "./shim";
import React from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, serializeAsJSON, exportToSvg, exportToBlob } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

const data = JSON.parse(document.getElementById("esketch-data")!.textContent!);
const name: string = document.getElementById("esketch-name")!.textContent || "drawing";
let api: any = null;

const current = () => serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local");

async function sendToEmacs() {
  const json = current();
  try { await navigator.clipboard.writeText(json); } catch { /* clipboard may be refused; the file still goes */ }
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([json], { type: "application/json" }));
  a.download = `${name}.excalidraw`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

const w = window as any;
w.esketchExport = current;
w.esketchSvg = async () => (await exportToSvg({ elements: api.getSceneElements(), appState: api.getAppState(), files: api.getFiles() })).outerHTML;
w.esketchPng = async () => (await exportToBlob({ elements: api.getSceneElements(), appState: api.getAppState(), files: api.getFiles(), mimeType: "image/png" })).size;
w.esketchSend = sendToEmacs;

function App() {
  return (
    <div style={{ height: "100vh" }}>
      <Excalidraw
        initialData={{ elements: data.elements, appState: { ...data.appState, name }, files: data.files, scrollToContent: true }}
        excalidrawAPI={(a: any) => { api = a; w.esketchApi = a; }}
        renderTopRightUI={() => (
          <button className="esketch-send" onClick={sendToEmacs}
            title="Copy the drawing for Emacs and save it to Downloads"
            style={{ padding: "0 12px", height: "2.25rem", borderRadius: 8, border: "1px solid #6965db",
                     background: "#6965db", color: "#fff", cursor: "pointer", fontSize: 14 }}>
            Send to Emacs
          </button>
        )}
      />
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
