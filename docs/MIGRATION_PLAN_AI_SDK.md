# Migration Plan: Vercel AI SDK v6

## Objective
Replace the existing CLI-based AI services (`claudecode.ts`, `codex.ts`) with the Vercel AI SDK v6 to provide a unified, standard interface for AI interactions, while maintaining support for MCP tools and "Thinking" capabilities.

## Analysis of Current State
- **Services**:
  - `claudecode.ts`: Spawns `claude` CLI, manages persistent session, manually parses JSON stream, handles MCP tools via system prompt.
  - `codex.ts`: Spawns `codex` CLI, manages session, parses JSONL stream.
- **UI**:
  - `AIInputBar.tsx`: Accepts input and model selection.
  - `AIResponseBlock.tsx`: Renders streaming response, thinking blocks, and tool calls.
- **MCP**:
  - `mcpClient.ts`: Manages MCP servers and tools.

## Proposed Architecture

## Required environment variables (AI SDK providers)

### Direct HTTP providers (Vercel AI SDK v6)

When using the Vercel AI SDK v6 direct HTTP providers, you must provide the provider API key via environment variables:

- Anthropic (`provider: "anthropic"`): `ANTHROPIC_API_KEY`
- OpenAI (`provider: "openai"`): `OPENAI_API_KEY`

If a required key is missing/empty, the app will throw a plain `Error` (instead of a generic `AI_APICallError`) so the UI can show an actionable message.

### Claude Code (local auth via `claude-agent-sdk`)

For `provider: "claude-code"` we **do not** call the Anthropic HTTP API at all.

Instead, the app uses the local-auth Claude Code runtime via [`query()`](../src/services/ai.ts:151) from `claude-agent-sdk` (installed as an npm alias to `@anthropic-ai/claude-agent-sdk`). Authentication comes from the user's existing Claude login and local config (typically under `~/.claude/`).

Implications:

- **No `ANTHROPIC_API_KEY` is required** for `claude-code`.
- Claude Code must already be installed / logged in on the machine.
- Tool calls (MCP) are exposed to Claude Code via an in-process MCP server created from the app's MCP manager.

### Running `pnpm tauri dev` with env vars

You can set env vars inline when starting dev:

```bash
ANTHROPIC_API_KEY="..." OPENAI_API_KEY="..." pnpm tauri dev
```

Or put them in your shell environment (e.g. in `~/.zshrc` / `~/.zprofile`) and restart your terminal before running:

```bash
pnpm tauri dev
```

### 1. New Dependencies
- `ai`: Core Vercel AI SDK.
- `@ai-sdk/anthropic`: Provider for Claude models.
- `@ai-sdk/openai`: Provider for OpenAI models.
- `zod`: For schema validation (required by AI SDK tools).

### 2. MCP Adapter (`src/lib/ai/mcp-adapter.ts`)
- **Purpose**: Convert MCP tools (JSON Schema) to AI SDK tools (Zod Schema).
- **Functionality**:
  - `getAIToolsFromMCP(mcpManager)`: Iterates over connected MCP tools.
  - Converts `inputSchema` to Zod objects dynamically.
  - Returns a dictionary of tools compatible with `streamText`.

### 3. Unified AI Service (`src/services/ai.ts`)
- **Purpose**: Central service to handle chat completions.
- **Functionality**:
  - `streamChat(messages, modelId, options)`:
    - Selects the correct provider (Anthropic vs OpenAI) based on `modelId`.
    - Configures "Thinking" parameters (budget) if applicable.
    - Injects MCP tools.
    - Calls `streamText` from `ai`.
    - Returns the stream result.

### 4. UI Updates
- **`AIInputBar.tsx`**:
  - Update to use the new service.
- **`AIResponseBlock.tsx`**:
  - Adapt to consume the `useChat` hook or the raw stream from `ai`.
  - The `useChat` hook is the recommended way to manage state in React.
  - We will likely wrap `AIResponseBlock` in a container that uses `useChat`.

## Migration Steps

1.  **Install Dependencies**: Add `ai`, `@ai-sdk/anthropic`, `@ai-sdk/openai`, `zod`.
2.  **Implement MCP Adapter**: Create `src/lib/ai/mcp-adapter.ts`.
3.  **Implement AI Service**: Create `src/services/ai.ts`.
4.  **Refactor UI**:
    - Create a new hook `useAI` (wrapping `useChat` or `useCompletion`).
    - Update `AIInputBar` and `AIResponseBlock` to use this hook.
5.  **Verify & Cleanup**:
    - Test with Claude (Thinking) and OpenAI models.
    - Verify MCP tool execution.
    - Remove `claudecode.ts` and `codex.ts`.

## Risks & Mitigations
- **Risk**: Loss of "agentic" behavior from `claude` CLI (e.g., file access).
  - **Mitigation**: Ensure MCP tools for file access are correctly registered and working. The `claude` CLI likely used internal tools; we must ensure our MCP setup covers these needs (read/write files).
- **Risk**: JSON Schema to Zod conversion complexity.
  - **Mitigation**: Use a robust mapping strategy or a library if needed, but a simple recursive mapper should cover most cases.

## Questions for User
- Are there any specific "magic" features of the `claude` CLI (besides MCP) that you rely on?
- Do you want to keep the "Terminal Mode" (`codex` CLI) as a separate concept, or merge it into the general AI chat?
