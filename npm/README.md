# @jasonkneen/infinitty

npm installer for [infinitty](https://github.com/jasonkneen/infinitty) — the
agent-native GPU terminal for macOS.

```sh
npm install -g @jasonkneen/infinitty
infinitty                              # launch the terminal
claude mcp add infinitty -- infinitty-mcp # register MCP tools
infinitty-agent run -- claude          # start a Channel-aware CLI
```

Downloads the signed release binaries for your version from GitHub Releases.
macOS 14+ (Apple Silicon & Intel, universal binaries).

`infinitty-agent` is provider-neutral: use `run -- <any-cli>` to register a
terminal agent for the lifetime of the process, or
`context --format plain`/`claude` from a provider hook. It uses the pane's
`INFINITTY_SOCKET` and leaves the wrapped CLI's PID, TTY, exit status, and
signals intact. When using the optional zsh integration, set
`INFINITTY_AGENT_AUTO_WRAP=0` to disable automatic wrapping.
