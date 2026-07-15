#!/usr/bin/env node
"use strict";
const path = require("path");
const { spawn } = require("child_process");
const bin = process.env.INFINITTY_MCP_BIN
  || path.join(__dirname, "..", "vendor", "infinitty-mcp");
const child = spawn(bin, process.argv.slice(2), { stdio: "inherit" });
child.on("error", (err) => {
  console.error(`infinitty: ${err.message} (re-run: npm rebuild @jasonkneen/infinitty)`);
  process.exit(1);
});
child.on("exit", (code) => process.exit(code ?? 0));
