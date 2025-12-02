#!/usr/bin/env node
import { startServer } from "./server.js";

// Parse port from environment or command line
const port = Number(process.env.PORT) || Number(process.argv[2]) || 3030;

console.log(`[com.flows.workflow] Starting widget process...`);
console.log(`  PID: ${process.pid}`);
console.log(`  Port: ${port}`);

// Handle graceful shutdown
process.on("SIGINT", () => {
  console.log("[com.flows.workflow] Received SIGINT, shutting down...");
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("[com.flows.workflow] Received SIGTERM, shutting down...");
  process.exit(0);
});

// Start the server
startServer(port).catch((err) => {
  console.error("[com.flows.workflow] Failed to start server:", err);
  process.exit(1);
});
