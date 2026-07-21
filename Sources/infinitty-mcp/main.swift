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
    var tv = timeval(tv_sec: time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var out = Array((line + "\n").utf8)
    _ = out.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }

    var response = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        response.append(contentsOf: buf[0..<n])
    }
    var text = String(decoding: response, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
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
        description: "Show, hide, or toggle infinitty's code sidebar (the Files / "
            + "Changes / Chat panel). Lets the assistant drive its own interface.",
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
        description: "Switch infinitty's sidebar to a tab: files, changes (git), or "
            + "chat. Opens the sidebar first if it is closed.",
        schema: [
            "type": "object",
            "properties": [
                "tab": [
                    "type": "string",
                    "enum": ["files", "changes", "chat"],
                    "description": "Which sidebar tab to show",
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
            "isError": text.hasPrefix("error:"),
        ])
    default:
        if let id { replyError(id: id, code: -32601, message: "method not found: \(method)") }
    }
}
