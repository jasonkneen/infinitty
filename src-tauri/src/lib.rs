// Infinitty - An AI-powered terminal application

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder, Emitter};
use tauri::webview::WebviewBuilder;
use tauri::menu::{ContextMenu, MenuBuilder, MenuItemBuilder, SubmenuBuilder, Menu, AboutMetadataBuilder};
use std::collections::HashMap;
use std::sync::Mutex;
use sysinfo::{System, CpuRefreshKind, MemoryRefreshKind, RefreshKind, Disks};
use serde::Serialize;

// Store for tracking embedded webviews
struct WebviewStore {
    webviews: HashMap<String, StoredWebview>,
}

struct StoredWebview {
    url: url::Url,
    trusted: bool,
}

// System metrics snapshot returned to frontend
#[derive(Serialize)]
struct SystemMetrics {
    cpu_usage: f32,
    memory_used_mb: u64,
    memory_total_mb: u64,
    disk_used_mb: u64,
    disk_total_mb: u64,
}

impl Default for WebviewStore {
    fn default() -> Self {
        Self {
            webviews: HashMap::new(),
        }
    }
}

// Chrome user agent string
const CHROME_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

#[tauri::command]
async fn create_embedded_webview(
    window: tauri::Window,
    app: tauri::AppHandle,
    webview_id: String,
    url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<String, String> {
    // Remove existing webview with same ID if any
    if let Some(existing) = app.get_webview(&webview_id) {
        let _ = existing.close();
    }

    println!("[WebView] Creating webview: id={}, url={}, pos=({},{}), size={}x{}",
             webview_id, url, x, y, width, height);

    let parsed_url: url::Url = url.parse().map_err(|e: url::ParseError| {
        println!("[WebView] URL parse error: {}", e);
        e.to_string()
    })?;

    validate_external_url(&parsed_url)?;

    let webview_builder = WebviewBuilder::new(&webview_id, WebviewUrl::External(parsed_url.clone()))
        .user_agent(CHROME_USER_AGENT)
        .auto_resize();  // Enable auto-resize

    // Create the webview attached to the window
    let webview = window.add_child(
        webview_builder,
        tauri::LogicalPosition::new(x, y),
        tauri::LogicalSize::new(width, height),
    ).map_err(|e| {
        println!("[WebView] Failed to add child webview: {}", e);
        e.to_string()
    })?;

    println!("[WebView] Webview created successfully: {:?}", webview.label());

    // Store reference
    if let Some(store) = app.try_state::<Mutex<WebviewStore>>() {
        let mut store = store.lock().unwrap();
        store.webviews.insert(webview_id.clone(), StoredWebview { url: parsed_url.clone(), trusted: true });
    }

    Ok(webview_id)
}

#[tauri::command]
async fn update_webview_bounds(
    app: tauri::AppHandle,
    webview_id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    if let Some(webview) = app.get_webview(&webview_id) {
        webview.set_position(tauri::LogicalPosition::new(x, y)).map_err(|e| e.to_string())?;
        webview.set_size(tauri::LogicalSize::new(width, height)).map_err(|e| e.to_string())?;
        Ok(())
    } else {
        Err("Webview not found".to_string())
    }
}

#[tauri::command]
async fn navigate_webview(
    app: tauri::AppHandle,
    webview_id: String,
    url: String,
) -> Result<(), String> {
    let parsed_url: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
    validate_external_url(&parsed_url)?;

    if let Some(webview) = app.get_webview(&webview_id) {
        webview.navigate(parsed_url.clone()).map_err(|e| e.to_string())?;

        // Update stored URL
        if let Some(store) = app.try_state::<Mutex<WebviewStore>>() {
            let mut store = store.lock().unwrap();
            if let Some(entry) = store.webviews.get_mut(&webview_id) {
                entry.url = parsed_url;
            }
        }
        Ok(())
    } else {
        Err("Webview not found".to_string())
    }
}

#[tauri::command]
async fn destroy_webview(
    app: tauri::AppHandle,
    webview_id: String,
) -> Result<(), String> {
    // Remove from store first
    if let Some(store) = app.try_state::<Mutex<WebviewStore>>() {
        let mut store = store.lock().unwrap();
        store.webviews.remove(&webview_id);
    }

    // Close the webview
    if let Some(webview) = app.get_webview(&webview_id) {
        webview.close().map_err(|e| e.to_string())?;
        Ok(())
    } else {
        // Not an error if already gone - could have been closed by user
        Ok(())
    }
}

#[tauri::command]
async fn execute_webview_script(
    app: tauri::AppHandle,
    webview_id: String,
    script: String,
) -> Result<String, String> {
    // NOTE: This is a powerful primitive. It is currently only used by the
    // internal element selector tooling. Do not expose to untrusted inputs.
    if script.len() > 100_000 {
        return Err("Script too large".to_string());
    }
    if let Some(store) = app.try_state::<Mutex<WebviewStore>>() {
        let store = store.lock().unwrap();
        match store.webviews.get(&webview_id) {
            Some(entry) if entry.trusted => {},
            _ => return Err("Webview is not trusted for script execution".to_string()),
        }
    } else {
        return Err("Webview store unavailable".to_string());
    }
    if let Some(webview) = app.get_webview(&webview_id) {
        // Execute JavaScript in the webview and return result
        let result = webview.eval(&script);
        match result {
            Ok(_) => Ok("executed".to_string()),
            Err(e) => Err(e.to_string()),
        }
    } else {
        Err("Webview not found".to_string())
    }
}

#[tauri::command]
async fn hide_all_webviews(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(store) = app.try_state::<Mutex<WebviewStore>>() {
        let store = store.lock().unwrap();
        for webview_id in store.webviews.keys() {
            if let Some(webview) = app.get_webview(webview_id) {
                // Move webview off-screen by setting position to far left
                let _ = webview.set_position(tauri::LogicalPosition::new(-10000.0, -10000.0));
            }
        }
    }
    Ok(())
}

#[tauri::command]
async fn show_all_webviews(_app: tauri::AppHandle) -> Result<(), String> {
    // This just signals to refresh - actual positions are set by update_webview_bounds
    // The webviews will be repositioned when update_webview_bounds is called
    Ok(())
}

#[tauri::command]
async fn create_new_window(app: tauri::AppHandle) -> Result<String, String> {
    let window_id = format!("window-{}", uuid::Uuid::new_v4());

    let _window = WebviewWindowBuilder::new(
        &app,
        &window_id,
        WebviewUrl::App("index.html".into())
    )
    .title("Infinitty")
    .inner_size(1200.0, 800.0)
    .min_inner_size(800.0, 600.0)
    .decorations(true)
    .transparent(false)
    .title_bar_style(tauri::TitleBarStyle::Overlay)
    .hidden_title(true)
    .build()
    .map_err(|e| e.to_string())?;

    // Note: Native macOS window tabbing is handled automatically by macOS
    // when windows have the same tabbingIdentifier. The system handles
    // merging windows into tabs via Window > Merge All Windows menu.

    Ok(window_id)
}

#[tauri::command]
async fn merge_windows_to_tabs(_app: tauri::AppHandle) -> Result<(), String> {
    // Native macOS tab merging happens through the Window menu
    // or by dragging tabs between windows
    Ok(())
}

#[tauri::command]
async fn move_tab_to_new_window(_app: tauri::AppHandle, _window_label: String) -> Result<(), String> {
    // Native macOS tab separation happens through the Window menu
    // or by dragging tabs out of the window
    Ok(())
}

#[tauri::command]
fn get_window_count(app: tauri::AppHandle) -> usize {
    app.webview_windows().len()
}

#[tauri::command]
fn get_current_directory() -> Result<String, String> {
    std::env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn get_system_metrics() -> Result<SystemMetrics, String> {
    // Refresh CPU + memory.
    let refresh = RefreshKind::new()
        .with_cpu(CpuRefreshKind::everything())
        .with_memory(MemoryRefreshKind::everything());
    let mut sys = System::new_with_specifics(refresh);
    sys.refresh_cpu();
    sys.refresh_memory();

    let cpu_usage = sys.global_cpu_info().cpu_usage();

    let memory_total_mb = sys.total_memory() / 1024;
    let memory_used_mb = sys.used_memory() / 1024;

    let mut disks = Disks::new_with_refreshed_list();
    disks.refresh();
    let mut disk_total_mb: u64 = 0;
    let mut disk_used_mb: u64 = 0;
    for disk in disks.list() {
        let total = disk.total_space() / (1024 * 1024);
        let available = disk.available_space() / (1024 * 1024);
        disk_total_mb += total;
        disk_used_mb += total.saturating_sub(available);
    }

    Ok(SystemMetrics {
        cpu_usage,
        memory_used_mb,
        memory_total_mb,
        disk_used_mb,
        disk_total_mb,
    })
}

#[tauri::command]
async fn get_git_status(path: String) -> Result<GitStatus, String> {
    use std::process::Command;

    // Get current branch
    let branch_output = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    let current_branch = String::from_utf8_lossy(&branch_output.stdout)
        .trim()
        .to_string();

    // Get list of branches
    let branches_output = Command::new("git")
        .args(["branch", "--format=%(refname:short)"])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    let branches: Vec<String> = String::from_utf8_lossy(&branches_output.stdout)
        .lines()
        .map(|s| s.to_string())
        .collect();

    // Get status with porcelain format for easy parsing
    let status_output = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    let status_text = String::from_utf8_lossy(&status_output.stdout);
    let mut staged: Vec<GitFileChange> = Vec::new();
    let mut unstaged: Vec<GitFileChange> = Vec::new();

    for line in status_text.lines() {
        if line.len() < 4 {
            continue;
        }
        let index_status = line.chars().nth(0).unwrap_or(' ');
        let worktree_status = line.chars().nth(1).unwrap_or(' ');
        let file_path = line[3..].to_string();

        // Determine status type
        let status = match (index_status, worktree_status) {
            ('M', _) | (_, 'M') => "modified",
            ('A', _) => "added",
            ('D', _) | (_, 'D') => "deleted",
            ('R', _) => "renamed",
            ('?', '?') => "untracked",
            _ => "modified",
        };

        // Check if staged (index status is not space or ?)
        if index_status != ' ' && index_status != '?' {
            staged.push(GitFileChange {
                path: file_path.clone(),
                status: status.to_string(),
            });
        }

        // Check if has working tree changes
        if worktree_status != ' ' {
            unstaged.push(GitFileChange {
                path: file_path,
                status: status.to_string(),
            });
        }
    }

    Ok(GitStatus {
        current_branch,
        branches,
        staged,
        unstaged,
    })
}

#[derive(serde::Serialize)]
struct GitFileChange {
    path: String,
    status: String,
}

#[derive(serde::Serialize)]
struct GitStatus {
    current_branch: String,
    branches: Vec<String>,
    staged: Vec<GitFileChange>,
    unstaged: Vec<GitFileChange>,
}

#[tauri::command]
async fn git_stage_file(path: String, file: String) -> Result<(), String> {
    use std::process::Command;
    Command::new("git")
        .args(["add", &file])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn git_unstage_file(path: String, file: String) -> Result<(), String> {
    use std::process::Command;
    Command::new("git")
        .args(["restore", "--staged", &file])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn git_commit(path: String, message: String) -> Result<(), String> {
    use std::process::Command;
    let output = Command::new("git")
        .args(["commit", "-m", &message])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    Ok(())
}

#[tauri::command]
async fn git_push(path: String) -> Result<(), String> {
    use std::process::Command;
    let output = Command::new("git")
        .args(["push"])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    Ok(())
}

#[tauri::command]
async fn git_checkout_branch(path: String, branch: String) -> Result<(), String> {
    use std::process::Command;
    let output = Command::new("git")
        .args(["checkout", &branch])
        .current_dir(&path)
        .output()
        .map_err(|e| e.to_string())?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    Ok(())
}

// File system operations for file explorer context menu
#[tauri::command]
async fn fs_create_file(path: String) -> Result<(), String> {
    let safe_path = sanitize_fs_path(&path)?;
    use std::fs::File;
    File::create(&safe_path).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn fs_create_directory(path: String) -> Result<(), String> {
    let safe_path = sanitize_fs_path(&path)?;
    std::fs::create_dir_all(&safe_path).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn fs_rename(old_path: String, new_path: String) -> Result<(), String> {
    let safe_old = sanitize_fs_path(&old_path)?;
    let safe_new = sanitize_fs_path(&new_path)?;
    std::fs::rename(&safe_old, &safe_new).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn fs_delete(path: String, is_directory: bool) -> Result<(), String> {
    let safe_path = sanitize_fs_path(&path)?;
    if is_directory {
        std::fs::remove_dir_all(&safe_path).map_err(|e| e.to_string())?;
    } else {
        std::fs::remove_file(&safe_path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn fs_copy(source: String, destination: String, is_directory: bool) -> Result<(), String> {
    let safe_source = sanitize_fs_path(&source)?;
    let safe_destination = sanitize_fs_path(&destination)?;
    if is_directory {
        copy_dir_recursive(&safe_source, &safe_destination).map_err(|e| e.to_string())?;
    } else {
        std::fs::copy(&safe_source, &safe_destination).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn copy_dir_recursive(src: &str, dst: &str) -> std::io::Result<()> {
    use std::fs;
    use std::path::Path;

    let src_path = Path::new(src);
    let dst_path = Path::new(dst);

    if !dst_path.exists() {
        fs::create_dir_all(dst_path)?;
    }

    for entry in fs::read_dir(src_path)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let src_child = entry.path();
        let dst_child = dst_path.join(entry.file_name());

        if file_type.is_dir() {
            copy_dir_recursive(
                src_child.to_str().unwrap(),
                dst_child.to_str().unwrap(),
            )?;
        } else {
            fs::copy(&src_child, &dst_child)?;
        }
    }
    Ok(())
}

#[tauri::command]
async fn fs_move(source: String, destination: String) -> Result<(), String> {
    let safe_source = sanitize_fs_path(&source)?;
    let safe_destination = sanitize_fs_path(&destination)?;
    std::fs::rename(&safe_source, &safe_destination).map_err(|e| e.to_string())?;
    Ok(())
}

fn sanitize_fs_path(path: &str) -> Result<String, String> {
    use std::path::{Path, Component};

    // Disallow empty paths and parent traversal.
    if path.trim().is_empty() {
        return Err("Empty path".to_string());
    }

    let p = Path::new(path);

    if !p.is_absolute() {
        return Err("Path must be absolute".to_string());
    }

    for comp in p.components() {
        if let Component::ParentDir = comp {
            return Err("Parent directory traversal is not allowed".to_string());
        }
    }

    // Restrict to the user's home directory when available.
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok();
    if let Some(home_dir) = home {
        let home_path = Path::new(&home_dir);
        if !p.starts_with(home_path) {
            return Err("File operations are restricted to the home directory".to_string());
        }
    }

    Ok(p.to_string_lossy().to_string())
}

fn validate_external_url(url: &url::Url) -> Result<(), String> {
    // Only allow http/https.
    let scheme = url.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(format!("Blocked URL scheme: {}", scheme));
    }

    // Block localhost.
    let host = url.host_str().unwrap_or_default();
    let blocked = ["localhost", "127.0.0.1", "0.0.0.0", "::1"];
    if blocked.contains(&host) {
        return Err(format!("Blocked URL host: {}", host));
    }

    // Block private IPv4 ranges.
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        let octets = ip.octets();
        let a = octets[0];
        let b = octets[1];
        if a == 10 || (a == 172 && (16..=31).contains(&b)) || (a == 192 && b == 168) {
            return Err(format!("Blocked private IP: {}", host));
        }
    }

    Ok(())
}

#[tauri::command]
async fn set_window_vibrancy(window: tauri::Window, vibrancy: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use tauri::window::{Effect, EffectState, EffectsBuilder};

        let effect = match vibrancy.as_str() {
            "sidebar" => Some(Effect::Sidebar),
            "header" => Some(Effect::HeaderView),
            "sheet" => Some(Effect::Sheet),
            "menu" => Some(Effect::Menu),
            "popover" => Some(Effect::Popover),
            "hudWindow" => Some(Effect::HudWindow),
            "titlebar" => Some(Effect::Titlebar),
            "selection" => Some(Effect::Selection),
            "contentBackground" => Some(Effect::ContentBackground),
            "windowBackground" => Some(Effect::WindowBackground),
            _ => None,
        };

        if let Some(eff) = effect {
            window.set_effects(EffectsBuilder::new()
                .effect(eff)
                .state(EffectState::Active)
                .build())
                .map_err(|e| e.to_string())?;
        } else {
            // Clear effects by setting empty effects
            window.set_effects(EffectsBuilder::new().build())
                .map_err(|e| e.to_string())?;
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = vibrancy;
        let _ = window;
    }

    Ok(())
}

#[tauri::command]
async fn show_split_context_menu(
    app: tauri::AppHandle,
    window: tauri::Window,
    x: f64,
    y: f64,
    pane_id: String,
    can_close: bool,
) -> Result<String, String> {
    use tauri::PhysicalPosition;

    let split_right = MenuItemBuilder::new("Split Right")
        .id(format!("split-right:{}", pane_id))
        .accelerator("CmdOrCtrl+D")
        .build(&app)
        .map_err(|e| e.to_string())?;

    let split_down = MenuItemBuilder::new("Split Down")
        .id(format!("split-down:{}", pane_id))
        .accelerator("Shift+CmdOrCtrl+D")
        .build(&app)
        .map_err(|e| e.to_string())?;

    let mut menu_builder = MenuBuilder::new(&app)
        .item(&split_right)
        .item(&split_down);

    if can_close {
        let separator = tauri::menu::PredefinedMenuItem::separator(&app)
            .map_err(|e| e.to_string())?;
        let close_pane = MenuItemBuilder::new("Close Pane")
            .id(format!("close-pane:{}", pane_id))
            .accelerator("CmdOrCtrl+W")
            .build(&app)
            .map_err(|e| e.to_string())?;
        menu_builder = menu_builder.item(&separator).item(&close_pane);
    }

    let menu = menu_builder.build().map_err(|e| e.to_string())?;

    // popup_at requires Position, not PhysicalPosition
    menu.popup_at(window, tauri::Position::Physical(PhysicalPosition::new(x as i32, y as i32)))
        .map_err(|e| e.to_string())?;

    Ok("menu_shown".to_string())
}

#[tauri::command]
async fn set_window_opacity(window: tauri::Window, opacity: f64) -> Result<(), String> {
    // opacity is 0-100, convert to 0.0-1.0
    let alpha = (opacity / 100.0).clamp(0.5, 1.0);

    #[cfg(target_os = "macos")]
    {
        use tauri::window::Color;
        window.set_background_color(Some(Color(0, 0, 0, (alpha * 255.0) as u8)))
            .map_err(|e| e.to_string())?;
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = alpha;
        let _ = window;
    }

    Ok(())
}

fn create_app_menu(app: &tauri::AppHandle) -> Result<Menu<tauri::Wry>, tauri::Error> {
    // File menu
    let new_tab = MenuItemBuilder::new("New Tab")
        .id("new-tab")
        .accelerator("CmdOrCtrl+T")
        .build(app)?;
    let new_window = MenuItemBuilder::new("New Window")
        .id("new-window")
        .accelerator("CmdOrCtrl+N")
        .build(app)?;
    let close_tab = MenuItemBuilder::new("Close Tab")
        .id("close-tab")
        .accelerator("CmdOrCtrl+W")
        .build(app)?;
    let close_window = MenuItemBuilder::new("Close Window")
        .id("close-window")
        .accelerator("Shift+CmdOrCtrl+W")
        .build(app)?;
    let settings = MenuItemBuilder::new("Settings")
        .id("settings")
        .accelerator("CmdOrCtrl+,")
        .build(app)?;

    let file_menu = SubmenuBuilder::new(app, "File")
        .item(&new_tab)
        .item(&new_window)
        .separator()
        .item(&close_tab)
        .item(&close_window)
        .separator()
        .item(&settings)
        .separator()
        .quit()
        .build()?;

    // Edit menu with standard items
    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .separator()
        .select_all()
        .build()?;

    // View menu
    let toggle_sidebar = MenuItemBuilder::new("Toggle Sidebar")
        .id("toggle-sidebar")
        .accelerator("CmdOrCtrl+B")
        .build(app)?;
    let zoom_in = MenuItemBuilder::new("Zoom In")
        .id("zoom-in")
        .accelerator("CmdOrCtrl+Plus")
        .build(app)?;
    let zoom_out = MenuItemBuilder::new("Zoom Out")
        .id("zoom-out")
        .accelerator("CmdOrCtrl+Minus")
        .build(app)?;
    let zoom_reset = MenuItemBuilder::new("Actual Size")
        .id("zoom-reset")
        .accelerator("CmdOrCtrl+0")
        .build(app)?;
    let command_palette = MenuItemBuilder::new("Command Palette")
        .id("command-palette")
        .accelerator("CmdOrCtrl+P")
        .build(app)?;

    let view_menu = SubmenuBuilder::new(app, "View")
        .item(&toggle_sidebar)
        .separator()
        .item(&zoom_in)
        .item(&zoom_out)
        .item(&zoom_reset)
        .separator()
        .item(&command_palette)
        .separator()
        .fullscreen()
        .build()?;

    // Terminal menu
    let split_right = MenuItemBuilder::new("Split Right")
        .id("split-right")
        .accelerator("CmdOrCtrl+D")
        .build(app)?;
    let split_down = MenuItemBuilder::new("Split Down")
        .id("split-down")
        .accelerator("Shift+CmdOrCtrl+D")
        .build(app)?;
    let clear_terminal = MenuItemBuilder::new("Clear")
        .id("clear-terminal")
        .accelerator("CmdOrCtrl+K")
        .build(app)?;

    let terminal_menu = SubmenuBuilder::new(app, "Terminal")
        .item(&split_right)
        .item(&split_down)
        .separator()
        .item(&clear_terminal)
        .build()?;

    // Window menu
    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .close_window()
        .build()?;

    // Help menu
    let about_metadata = AboutMetadataBuilder::new()
        .name(Some("Infinitty".to_string()))
        .version(Some("0.1.0".to_string()))
        .build();

    let help_menu = SubmenuBuilder::new(app, "Help")
        .about(Some(about_metadata))
        .build()?;

    // Build the complete menu
    let menu = MenuBuilder::new(app)
        .item(&file_menu)
        .item(&edit_menu)
        .item(&view_menu)
        .item(&terminal_menu)
        .item(&window_menu)
        .item(&help_menu)
        .build()?;

    Ok(menu)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_pty::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .manage(Mutex::new(WebviewStore::default()))
        .setup(|app| {
            // Create and set the application menu
            let menu = create_app_menu(app.handle())?;
            app.set_menu(menu)?;

            // Listen for menu events and emit to frontend
            app.on_menu_event(move |app, event| {
                let menu_id = event.id().0.as_str();
                // Emit to all windows
                if let Err(e) = app.emit("menu-action", menu_id) {
                    eprintln!("Failed to emit menu event: {}", e);
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            create_new_window,
            merge_windows_to_tabs,
            move_tab_to_new_window,
            get_window_count,
            get_current_directory,
            get_system_metrics,
            get_git_status,
            git_stage_file,
            git_unstage_file,
            git_commit,
            git_push,
            git_checkout_branch,
            set_window_vibrancy,
            set_window_opacity,
            show_split_context_menu,
            create_embedded_webview,
            update_webview_bounds,
            navigate_webview,
            destroy_webview,
            execute_webview_script,
            hide_all_webviews,
            show_all_webviews,
            fs_create_file,
            fs_create_directory,
            fs_rename,
            fs_delete,
            fs_copy,
            fs_move,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
