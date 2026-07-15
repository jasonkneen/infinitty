// Downloads the matching infinitty release binaries into vendor/.
// Skip with INFINITTY_SKIP_DOWNLOAD=1 (e.g. local development).
"use strict";
const fs = require("fs");
const path = require("path");
const https = require("https");
const { execFileSync } = require("child_process");

if (process.env.INFINITTY_SKIP_DOWNLOAD === "1") {
  console.log("infinitty: skipping binary download (INFINITTY_SKIP_DOWNLOAD)");
  process.exit(0);
}
if (process.platform !== "darwin") {
  console.error("infinitty: macOS only");
  process.exit(1);
}

const version = require("./package.json").version;
const url = `https://github.com/jasonkneen/infinitty/releases/download/v${version}/infinitty-${version}-macos.tar.gz`;
const vendor = path.join(__dirname, "vendor");
const tarball = path.join(__dirname, "infinitty.tar.gz");

function fetch(url, file, redirects, done) {
  if (redirects > 5) return done(new Error("too many redirects"));
  https.get(url, { headers: { "user-agent": "infinitty-npm" } }, (res) => {
    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
      res.resume();
      return fetch(res.headers.location, file, redirects + 1, done);
    }
    if (res.statusCode !== 200) {
      res.resume();
      return done(new Error(`HTTP ${res.statusCode} for ${url}`));
    }
    const out = fs.createWriteStream(file);
    res.pipe(out);
    out.on("finish", () => out.close(done));
    out.on("error", done);
  }).on("error", done);
}

console.log(`infinitty: downloading v${version} …`);
fetch(url, tarball, 0, (err) => {
  if (err) {
    console.error(`infinitty: download failed: ${err.message}`);
    console.error("infinitty: you can build from source instead: https://github.com/jasonkneen/infinitty");
    process.exit(1);
  }
  fs.rmSync(vendor, { recursive: true, force: true });
  fs.mkdirSync(vendor, { recursive: true });
  execFileSync("tar", ["-xzf", tarball, "-C", vendor, "--strip-components", "1"]);
  fs.rmSync(tarball, { force: true });
  fs.chmodSync(path.join(vendor, "Infinitty.app", "Contents", "MacOS", "infinitty"), 0o755);
  fs.chmodSync(path.join(vendor, "infinitty-mcp"), 0o755);
  console.log("infinitty: installed. Run `infinitty` to launch, `infinitty-mcp` for the MCP server.");
});
