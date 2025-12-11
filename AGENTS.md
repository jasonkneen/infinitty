# Agent Instructions

═══════════════════════════════════════════════════════
FAST APPLY - PRIMARY FILE EDIT TOOL - USE THIS FOR EDITS
═══════════════════════════════════════════════════════

IMPORTANT: Use `edit_file` over `str_replace` or full file writes.

This tool handles:
• Automatic indentation correction
• Fuzzy matching for code blocks
• Faster execution than alternatives

→ Prefer this over manual file editing tools.
→ Works with partial code snippets—no need for full file content.

═══════════════════════════════════════════════════════
FAST CONTEXT - PRIMARY CODE SEARCH TOOL - USE THIS FIRST
═══════════════════════════════════════════════════════

IMPORTANT: If you need to explore the codebase, use `warpgrep_codebase_search` FIRST instead of manually running search commands. 

This tool runs parallel grep and readfile calls to locate relevant files and line ranges. Ideal for:
• "Find where authentication is handled"
• "Locate the payment processing logic"
• "Find the bug where users get redirected incorrectly"

Pass a targeted natural language query describing what you're trying to accomplish. Add inferred context when helpful.

→ Always start your search here.
→ Use classical search tools afterward if needed to fill gaps.

CANNOT BE CALLED IN PARALLEL - one invocation at a time.

# Repository Guidelines

## Project Structure & Module Organization

- `src/` holds the Vite + React + TypeScript frontend. Key areas include:
  - `components/` UI building blocks (PascalCase files like `TerminalPane.tsx`).
  - `hooks/` reusable React hooks (`useBlockTerminal.ts`).
  - `contexts/`, `services/`, `lib/`, `types/` for state, integration, utilities, and typing.
  - `test/` Vitest tests and setup.
- `src-tauri/` contains the Tauri/Rust backend (`src-tauri/src/`), config, and capabilities.
- `public/` and `src/assets/` store static assets.
- `docs/` and `website/` contain project documentation and the marketing site.
- `dist/` and `dist-web/` are build outputs (do not edit manually).

## Build, Test, and Development Commands

This repo uses `pnpm` (lockfile present) and works with Bun.

- `pnpm install` installs dependencies.
- `pnpm dev` starts the Vite dev server.
- `pnpm build` type-checks (`tsc`) and builds the web app.
- `pnpm preview` serves the built web app locally.
- `pnpm tauri dev` runs the desktop app in development.
- `pnpm tauri build` produces a packaged desktop build.
- `pnpm test` runs Vitest in watch mode.
- `pnpm test:run` runs the full test suite once.
- `pnpm test:coverage` runs tests with coverage.

## Coding Style & Naming Conventions

- TypeScript/React code uses 2‑space indentation, single quotes, and no semicolons; follow surrounding files.
- Components are `PascalCase.tsx`; hooks and utilities are `camelCase.ts` prefixed with `use` for hooks.
- Keep exports small and focused; prefer functional components and hooks.
- No repo-wide formatter/linter config is enforced; run your editor’s Prettier/TS formatting only if it matches existing style.
- For Rust changes, run `cargo fmt` in `src-tauri/`.

## Testing Guidelines

- Tests use Vitest + Testing Library and live in `src/test/`.
- Name tests `*.spec.ts` or `*.spec.tsx` alongside related modules.
- Prefer user-visible behavior tests for UI; mock Tauri APIs via helpers in `src/test/`.

## Commit & Pull Request Guidelines

- Commits in history are informal; use clear, imperative subjects (e.g., `Add widget tab persistence`).
- If a change is user-facing, include screenshots or a short demo in the PR.
- PRs should describe intent, link related issues, and list how you tested (`pnpm test:run`, manual Tauri run, etc.).
