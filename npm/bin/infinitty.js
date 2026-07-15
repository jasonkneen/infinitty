#!/usr/bin/env node
"use strict";
const path = require("path");
const { spawn } = require("child_process");
const bin = process.env.INFINITTY_BIN
  || path.join(__dirname, "..", "vendor", "Infinitty.app", "Contents", "MacOS", "infinitty");
// GUI app: launch detached so the shell prompt returns immediately.
const child = spawn(bin, process.argv.slice(2), { detached: true, stdio: "ignore" });
child.on("error", (err) => {
  console.error(`infinitty: ${err.message} (re-run: npm rebuild @jasonkneen/infinitty)`);
  process.exit(1);
});
child.unref();
