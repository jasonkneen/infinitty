# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

# Project Overview

"Infinitty" is a hybrid terminal application built with Tauri, React, and TypeScript. It combines a web-based frontend with a Rust backend to provide terminal capabilities, file management, and a widget system.

## Key Technologies

- **Frontend:** React, TypeScript, Tailwind CSS, Vite
- **Backend:** Rust, Tauri
- **Terminal:** xterm.js
- **State Management:** React Context / Hooks
- **Testing:** Vitest, React Testing Library
- **Package Manager:** pnpm (recommended) or bun

# Development

## Setup and Running

1.  **Install Dependencies:**
    ```bash
    pnpm install
    ```

2.  **Start Development Server:**
    To run the full desktop application (Frontend + Backend):
    ```bash
    pnpm tauri dev
    ```
    To run only the web frontend (note: Tauri APIs will not be available):
    ```bash
    pnpm dev
    ```

3.  **Build for Production:**
    ```bash
    pnpm tauri build
    ```

## Testing

-   **Run Unit Tests:**
    ```bash
    pnpm test
    ```
-   **Run Tests with Coverage:**
    ```bash
    pnpm run test:coverage
    ```

# Architecture

## Directory Structure

-   `src/`: React frontend source code.
    -   `components/`: Reusable UI components.
    -   `hooks/`: Custom React hooks.
    -   `contexts/`: Global state management.
    -   `services/`: Business logic and API services.
    -   `widget-host/` & `widget-sdk/`: Widget system implementation.
    -   `src-tauri/`: Rust backend source code.
        -   `src/lib.rs`: Main entry point, command definitions, and plugin setup.
        -   `src/main.rs`: Application bootstrap.

## Backend (Rust/Tauri)

The backend handles system-level operations that the browser sandbox cannot access.
Key features implemented in `src-tauri/src/lib.rs`:
-   **Commands:** Exposed to frontend via `#[tauri::command]`.
-   **Git Operations:** `get_git_status`, `git_commit`, etc.
-   **File System:** `fs_create_file`, `fs_copy`, etc.
-   **Window Management:** Custom window creation, vibrancy effects (`set_window_vibrancy`), and tab management.
-   **WebViews:** Dynamic creation and management of embedded webviews (`create_embedded_webview`), likely used for widgets.

## Frontend (React)

The frontend interfaces with the backend using Tauri's IPC mechanism.
-   **Tauri Interop:** Frontend calls Rust commands using `invoke`.
-   **No Path Aliases:** Imports use relative paths (e.g., `../../components`).

# Common Tasks

## Adding a New Tauri Command

1.  Define the function in `src-tauri/src/lib.rs` with `#[tauri::command]`.
2.  Register the command in the `tauri::generate_handler!` macro in the `run()` function.
3.  Invoke the command from the frontend using `invoke('command_name', { args })`.

## Working with Widgets

The project appears to support embedded widgets via webviews.
-   Check `src/widget-sdk/` for widget development interfaces.
-   Backend support is provided via `create_embedded_webview` and related commands in `lib.rs`.
