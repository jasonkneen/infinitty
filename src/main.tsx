import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";
import { initShellEnv } from "./lib/shellEnv";

// Initialize shell environment early to capture PATH for GUI app
// This runs async but caches the result for later use
initShellEnv().catch((err) => {
  console.error('[App] Failed to initialize shell environment:', err)
})

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
