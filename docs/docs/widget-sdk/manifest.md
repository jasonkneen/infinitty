---
sidebar_position: 2
---

# Widget Manifest

The `manifest.json` file defines your widget's metadata, capabilities, and integration points.

## Complete Example

```json
{
  "id": "com.example.my-widget",
  "name": "My Awesome Widget",
  "version": "1.0.0",
  "description": "A widget that does awesome things",
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://example.com"
  },
  "license": "MIT",
  "icon": "icon.png",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "styles": "dist/styles.css",
  "executionModel": "inline",
  "port": 3000,
  "activationEvents": [
    "onStartup",
    "onCommand:my-widget.action",
    "onWidget:com.example.my-widget",
    "onEvent:custom-event"
  ],
  "engines": {
    "infinitty": ">=0.1.0"
  },
  "dependencies": {
    "lodash": "^4.17.0"
  },
  "contributes": {
    "commands": [
      {
        "id": "my-widget.action",
        "title": "Do Something",
        "category": "My Widget",
        "icon": "action-icon.svg",
        "shortcut": "Cmd+Shift+A"
      }
    ],
    "tools": [
      {
        "name": "my_tool",
        "description": "A tool that does something useful",
        "inputSchema": {
          "type": "object",
          "properties": {
            "input": { "type": "string" }
          },
          "required": ["input"]
        }
      }
    ],
    "configuration": {
      "title": "My Widget Settings",
      "properties": {
        "my-widget.enabled": {
          "type": "boolean",
          "default": true,
          "description": "Enable or disable the widget"
        },
        "my-widget.timeout": {
          "type": "number",
          "default": 5000,
          "minimum": 1000,
          "maximum": 30000,
          "description": "Operation timeout in milliseconds"
        },
        "my-widget.theme": {
          "type": "string",
          "default": "dark",
          "enum": ["light", "dark", "auto"],
          "description": "Widget theme preference"
        }
      }
    },
    "menus": [
      {
        "command": "my-widget.action",
        "group": "1_widget"
      }
    ]
  }
}
```

## Field Reference

### Identity

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier, e.g., `com.example.my-widget` |
| `name` | string | Yes | Display name shown in UI |
| `version` | string | Yes | Semantic version |
| `description` | string | No | Short description |
| `author` | string or object | No | Author information |
| `license` | string | No | License identifier (e.g., MIT, Apache-2.0) |
| `icon` | string | No | Icon path or data URI |

### Entry Points

| Field | Type | Description |
|-------|------|-------------|
| `main` | string | Compiled JavaScript entry point |
| `ui` | string | React component entry point |
| `styles` | string | Optional CSS stylesheet |

### Execution Model

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `executionModel` | "inline" \| "process" \| "webworker" | "inline" | How the widget is executed |
| `port` | number | 3000 | Default port for process-based widgets |
| `extensionPath` | string | auto | Path to widget directory (set by discovery) |

### Requirements

| Field | Type | Description |
|-------|------|-------------|
| `engines` | object | Minimum Infinitty version requirement |
| `dependencies` | object | Runtime dependencies |

## Activation Events

Control when your widget is loaded and initialized:

### onStartup
Activate immediately when Infinitty starts.

```json
"activationEvents": ["onStartup"]
```

### onCommand
Activate when a specific command is invoked.

```json
"activationEvents": ["onCommand:my-widget.action"]
```

### onWidget
Activate when a widget of a certain type is opened.

```json
"activationEvents": ["onWidget:com.example.my-widget"]
```

### onEvent
Activate on custom events.

```json
"activationEvents": ["onEvent:my-custom-event"]
```

## Contributions

Define what your widget contributes to the system.

### Commands

```json
"contributes": {
  "commands": [
    {
      "id": "my-widget.action",
      "title": "My Action",
      "category": "My Widget",
      "icon": "icon.svg",
      "shortcut": "Cmd+Shift+A"
    }
  ]
}
```

Commands become available in the command palette and can be invoked by other widgets.

### Tools

Register AI/Claude tools:

```json
"contributes": {
  "tools": [
    {
      "name": "my_tool",
      "description": "Does something useful",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Search query"
          },
          "limit": {
            "type": "number",
            "description": "Result limit",
            "default": 10
          }
        },
        "required": ["query"]
      }
    }
  ]
}
```

Tools follow JSON Schema format and are callable by Claude and other AI models.

### Configuration

Define widget settings:

```json
"contributes": {
  "configuration": {
    "title": "My Widget",
    "properties": {
      "my-widget.enabled": {
        "type": "boolean",
        "default": true,
        "description": "Enable/disable the widget"
      },
      "my-widget.timeout": {
        "type": "number",
        "default": 5000,
        "minimum": 1000,
        "maximum": 30000,
        "description": "Timeout in ms"
      },
      "my-widget.apiKey": {
        "type": "string",
        "description": "API key for external service"
      },
      "my-widget.options": {
        "type": "array",
        "default": ["option1", "option2"],
        "description": "List of options"
      },
      "my-widget.mode": {
        "type": "string",
        "enum": ["development", "production"],
        "default": "development",
        "description": "Execution mode"
      }
    }
  }
}
```

Configuration types:
- `string` - Text input
- `number` - Numeric input
- `boolean` - Toggle
- `array` - List of values
- `object` - Complex object

### Menus

Control where commands appear:

```json
"contributes": {
  "menus": [
    {
      "command": "my-widget.action",
      "group": "1_widget",
      "when": "some-context"
    }
  ]
}
```

## Publishing

When publishing your widget:

1. **Version your manifest** - Update version following semver
2. **Specify dependencies** - List all required packages
3. **Document commands and tools** - Clear descriptions for discoverability
4. **Add an icon** - PNG or SVG for visual identification
5. **Include author information** - Credit your work
6. **Test thoroughly** - Verify all contributions work

## Validation

Validate your manifest:

```bash
# Using Infinitty CLI
infinitty widget validate manifest.json

# Or manually check:
# - ID is unique and in format: com.vendor.name
# - Version is valid semver: X.Y.Z
# - All paths exist relative to manifest
# - JSON is valid (no trailing commas, etc)
```

## Best Practices

1. **Use reverse domain naming** for IDs: `com.company.widget-name`
2. **Keep versions semantic** - Major.Minor.Patch
3. **Describe clearly** - Make commands and tools discoverable
4. **Minimize activation** - Only use events you need
5. **Include icons** - Makes widgets recognizable
6. **Document schema** - Clear inputSchema for tools
7. **Test manifest** - Verify before distribution

## Examples

### Minimal Widget

```json
{
  "id": "com.example.simple",
  "name": "Simple Widget",
  "version": "1.0.0",
  "main": "dist/index.js",
  "ui": "dist/index.tsx"
}
```

### Tool-focused Widget

```json
{
  "id": "com.example.tools",
  "name": "Tools Widget",
  "version": "1.0.0",
  "main": "dist/index.js",
  "contributes": {
    "tools": [
      {
        "name": "search_docs",
        "description": "Search documentation",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string" }
          },
          "required": ["query"]
        }
      }
    ]
  }
}
```

### Command-focused Widget

```json
{
  "id": "com.example.commands",
  "name": "Commands Widget",
  "version": "1.0.0",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "contributes": {
    "commands": [
      {
        "id": "my-widget.deploy",
        "title": "Deploy Application",
        "category": "My Widget"
      }
    ]
  }
}
```

## Next Steps

- [Widget Lifecycle](lifecycle)
- [SDK Overview](overview)
- [Create Your First Widget](../getting-started/first-widget)
