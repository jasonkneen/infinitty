import Darwin
import Foundation

// infinitty-mcp: a dependency-free MCP stdio server that bridges tool calls to
// the infinitty app control socket. Register it with any MCP client:
//   claude mcp add infinitty -- /path/to/infinitty-mcp
// Discovery: $INFINITTY_APP_SOCKET, else /tmp/infinitty-current.sock.

// Ignore SIGPIPE: a control-socket or stdout write to a peer that has gone
// away must fail with EPIPE, not kill this process (the app does the same).
signal(SIGPIPE, SIG_IGN)

// MARK: - socket bridge

func infinittyRequest(_ line: String, timeout: Int32 = 130) -> String {
    let path = ProcessInfo.processInfo.environment["INFINITTY_APP_SOCKET"]
        ?? "/tmp/infinitty-current.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "error: cannot create socket" }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple -> Bool in
        tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else { return false }
            for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[bytes.count] = 0
            return true
        }
    }
    guard ok else { return "error: socket path too long" }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else {
        return "error: infinitty is not running (no socket at \(path))"
    }
    var readTimeout = timeval(tv_sec: time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
    var writeTimeout = timeval(tv_sec: time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

    let out = Array((line + "\n").utf8)
    let didWrite = out.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, base.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
    guard didWrite else {
        return "error: could not write request: \(String(cString: strerror(errno)))"
    }

    var response = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            response.append(contentsOf: buf[0..<n])
            continue
        }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            return "error: timed out waiting for infinitty response"
        }
        if n < 0 { return "error: could not read response: \(String(cString: strerror(errno)))" }
        break
    }
    var text = String(decoding: response, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

// MARK: - browser bridge

/// Browser commands travel as a base64url-encoded JSON object rather than as
/// space-delimited arguments. URLs, selectors, comments, and typed text can
/// therefore contain whitespace and arbitrary punctuation without changing the
/// app-control protocol's framing.
private let maximumBrowserRequestBytes = 48_000

func browserCall(
    _ operation: String,
    arguments: [String: Any] = [:],
    timeout: Int32 = 55
) -> String {
    var payload = arguments
    payload["v"] = 1
    payload["op"] = operation
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload) else {
        return "error: could not encode browser request"
    }
    guard data.count <= maximumBrowserRequestBytes else {
        return "error: browser request exceeds \(maximumBrowserRequestBytes) bytes"
    }
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return infinittyRequest("browser \(encoded)", timeout: timeout)
}

// MARK: - tool definitions

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let invoke: ([String: Any]) -> String
}

func paneArg(_ args: [String: Any]) -> String {
    if let n = args["pane"] as? Int { return String(n) }
    if let s = args["pane"] as? String { return s }
    return "0"
}

let paneProperty: [String: Any] = [
    "pane": ["type": "integer", "description": "Pane id from infinitty_list_panes"],
]

let browserIDProperty: [String: Any] = [
    "browserId": [
        "type": "string",
        "description": "Browser id returned by infinitty_browser_open or infinitty_browser_list",
    ],
]

let browserSnapshotProperty = browserIDProperty.merging([
    "snapshotId": [
        "type": "string",
        "description": "Fresh snapshot id returned by infinitty_browser_snapshot",
    ],
] as [String: Any]) { a, _ in a }

let tools: [Tool] = [
    Tool(
        name: "infinitty_list_panes",
        description: "List infinitty panes (terminals) with id, title, focus state, and size.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in infinittyRequest("list") }
    ),
    Tool(
        name: "infinitty_toggle_quick_terminal",
        description: "Show or hide infinitty's persistent quick terminal.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in infinittyRequest("toggle-quick-terminal") }
    ),
    Tool(
        name: "infinitty_sidebar",
        description: "Show, hide, or toggle infinitty's Files pane. The Files pane "
            + "contains the Files / Changes switch.",
        schema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["show", "hide", "toggle"],
                    "description": "show, hide, or toggle (default toggle)",
                ] as [String: Any],
            ],
        ],
        invoke: { args in infinittyRequest("sidebar \(args["action"] as? String ?? "toggle")") }
    ),
    Tool(
        name: "infinitty_sidebar_tab",
        description: "Open or focus a Files/Changes pane or the independent Chat pane.",
        schema: [
            "type": "object",
            "properties": [
                "tab": [
                    "type": "string",
                    "enum": ["files", "changes", "chat"],
                    "description": "Which panel content to show",
                ] as [String: Any],
            ],
            "required": ["tab"],
        ],
        invoke: { args in infinittyRequest("sidebar-tab \(args["tab"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_chat_model",
        description: "Set the infinitty sidebar chat's model (e.g. \"Claude Sonnet 5\", "
            + "\"claude\", \"gpt\", \"auto\"). Opens the chat first.",
        schema: [
            "type": "object",
            "properties": [
                "model": [
                    "type": "string",
                    "description": "Model name or substring to select",
                ] as [String: Any],
            ],
            "required": ["model"],
        ],
        invoke: { args in infinittyRequest("chat-model \(args["model"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_chat_effort",
        description: "Set the infinitty sidebar chat's reasoning effort: auto, low, "
            + "medium, or high. Opens the chat first.",
        schema: [
            "type": "object",
            "properties": [
                "effort": [
                    "type": "string",
                    "enum": ["auto", "low", "medium", "high"],
                    "description": "Reasoning effort level",
                ] as [String: Any],
            ],
            "required": ["effort"],
        ],
        invoke: { args in infinittyRequest("chat-effort \(args["effort"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_run",
        description: "Run a shell command in a pane and wait for it to finish. "
            + "Returns JSON with exitCode and the command's exact output. "
            + "Requires infinitty shell integration (OSC 133) in that pane.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "command": ["type": "string", "description": "Shell command to run"],
            ]) { a, _ in a },
            "required": ["pane", "command"],
        ],
        invoke: { args in
            infinittyRequest("run \(paneArg(args)) \(args["command"] as? String ?? "")")
        }
    ),
    Tool(
        name: "infinitty_screen",
        description: "Read a pane's visible screen as plain text.",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("screen \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_history",
        description: "Read the last N lines of a pane including scrollback.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "lines": ["type": "integer", "description": "How many lines (default 100)"],
            ]) { a, _ in a },
            "required": ["pane"],
        ],
        invoke: { args in
            infinittyRequest("history \(paneArg(args)) \(args["lines"] as? Int ?? 100)")
        }
    ),
    Tool(
        name: "infinitty_send",
        description: "Type text into a pane. Set submit=false to type without pressing return "
            + "(for TUIs, partial input, or control sequences).",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "text": ["type": "string"],
                "submit": ["type": "boolean", "description": "Press return after (default true)"],
            ]) { a, _ in a },
            "required": ["pane", "text"],
        ],
        invoke: { args in
            let cmd = (args["submit"] as? Bool ?? true) ? "send-line" : "send"
            return infinittyRequest("\(cmd) \(paneArg(args)) \(args["text"] as? String ?? "")")
        }
    ),
    Tool(
        name: "infinitty_last_output",
        description: "Exact output of the last completed command in a pane (OSC 133).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("last-output \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_exit_code",
        description: "Exit code of the last completed command in a pane (OSC 133).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("exit-code \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_new_tab",
        description: "Open a new infinitty tab. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": [
                "cwd": ["type": "string", "description": "Shell starting directory (absolute path)"],
            ],
        ],
        invoke: { args in
            let cwd = args["cwd"] as? String ?? ""
            return infinittyRequest(cwd.isEmpty ? "new-tab" : "new-tab \(cwd)")
        }
    ),
    Tool(
        name: "infinitty_new_window",
        description: "Open a new infinitty window. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": [
                "cwd": ["type": "string", "description": "Shell starting directory (absolute path)"],
            ],
        ],
        invoke: { args in
            let cwd = args["cwd"] as? String ?? ""
            return infinittyRequest(cwd.isEmpty ? "new-window" : "new-window \(cwd)")
        }
    ),
    Tool(
        name: "infinitty_split",
        description: "Split a pane. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "direction": [
                    "type": "string", "enum": ["right", "left", "down", "up"],
                ],
            ]) { a, _ in a },
            "required": ["pane", "direction"],
        ],
        invoke: { args in
            infinittyRequest("split \(paneArg(args)) \(args["direction"] as? String ?? "right")")
        }
    ),
    Tool(
        name: "infinitty_focus",
        description: "Raise and focus a pane.",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("focus \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_close",
        description: "Close a pane (terminates its shell).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("close \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_activity",
        description: "Show a short status message in infinitty's notch live-activity widget.",
        schema: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
        ],
        invoke: { args in infinittyRequest("activity \(args["text"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_browser_open",
        description: "Open or focus a native browser panel. Optionally navigate it to a URL. "
            + "Use its browserId with the other infinitty_browser_* tools.",
        schema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "Optional URL to load"],
                "anchorPane": [
                    "type": "integer",
                    "description": "Terminal pane whose tab should host the browser (default: key tab)",
                ],
            ],
        ],
        invoke: { args in browserCall("open", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_list",
        description: "List browser panels and their current URL, title, loading state, and viewport mode.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in browserCall("list") }
    ),
    Tool(
        name: "infinitty_browser_navigate",
        description: "Navigate a browser panel to a URL and wait for the navigation result.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "url": ["type": "string", "description": "Absolute URL, or a host/search-like URL"],
            ]) { a, _ in a },
            "required": ["browserId", "url"],
        ],
        invoke: { args in browserCall("navigate", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_snapshot",
        description: "Return a compact DOM-first snapshot of visible interactive elements. "
            + "Use the returned ref values for click, type, or press; take a new snapshot after navigation.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "maxNodes": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 250,
                    "description": "Maximum interactive elements to return (default 80)",
                ],
            ]) { a, _ in a },
            "required": ["browserId"],
        ],
        invoke: { args in browserCall("snapshot", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_click",
        description: "Click an interactive element identified by a fresh browser snapshot ref.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "ref": ["type": "string", "description": "Element ref from infinitty_browser_snapshot"],
            ]) { a, _ in a },
            "required": ["browserId", "snapshotId", "ref"],
        ],
        invoke: { args in browserCall("click", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_type",
        description: "Set or append text in an input, textarea, or contenteditable element from a fresh snapshot.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "ref": ["type": "string", "description": "Element ref from infinitty_browser_snapshot"],
                "text": ["type": "string", "description": "Text to enter"],
                "mode": [
                    "type": "string",
                    "enum": ["replace", "append"],
                    "description": "Replace existing text (default) or append",
                ],
            ]) { a, _ in a },
            "required": ["browserId", "snapshotId", "ref", "text"],
        ],
        invoke: { args in browserCall("type", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_press",
        description: "Dispatch a key to the focused page element, or to an optional fresh snapshot ref and snapshotId.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "key": ["type": "string", "description": "Key name, e.g. Enter, Escape, ArrowDown"],
                "ref": ["type": "string", "description": "Optional focused-element ref from a fresh snapshot"],
            ]) { a, _ in a },
            "required": ["browserId", "key"],
        ],
        invoke: { args in browserCall("press", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_scroll",
        description: "Scroll a browser panel by CSS pixels; positive deltaY scrolls down.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "deltaX": ["type": "number", "description": "Horizontal pixels (default 0)"],
                "deltaY": ["type": "number", "description": "Vertical pixels (default 500)"],
            ]) { a, _ in a },
            "required": ["browserId"],
        ],
        invoke: { args in browserCall("scroll", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_screenshot",
        description: "Capture the visible browser panel and return the local artifact path.",
        schema: ["type": "object", "properties": browserIDProperty, "required": ["browserId"]],
        invoke: { args in browserCall("screenshot", arguments: args) }
    ),
]

// MARK: - JSON-RPC over stdio (newline-delimited)

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Browser operations return structured `{ "ok": false, "error": … }`
/// replies from the app. Surface those as MCP tool errors just like the
/// established line-protocol `error:` responses.
func isToolError(_ text: String) -> Bool {
    guard !text.hasPrefix("error:") else { return true }
    guard let data = text.data(using: .utf8),
          let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ok = response["ok"] as? Bool else {
        return false
    }
    return !ok
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]

    switch method {
    case "initialize":
        guard let id else { break }
        reply(id: id, result: [
            "protocolVersion": (msg["params"] as? [String: Any])?["protocolVersion"] as? String
                ?? "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "infinitty", "version": "0.1"],
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        if let id { reply(id: id, result: [:]) }
    case "tools/list":
        guard let id else { break }
        reply(id: id, result: [
            "tools": tools.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.schema]
            },
        ])
    case "tools/call":
        guard let id else { break }
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            replyError(id: id, code: -32602, message: "unknown tool \(name)")
            continue
        }
        let text = tool.invoke(args)
        reply(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isToolError(text),
        ])
    default:
        if let id { replyError(id: id, code: -32601, message: "method not found: \(method)") }
    }
}
