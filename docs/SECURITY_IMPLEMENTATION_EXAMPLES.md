# WebView XSS Prevention - Implementation Examples

## URL Validation Function

This validation function is implemented in both `TabsContext.tsx` and `WebViewPane.tsx` to ensure consistent security checks across the application.

### Validation Logic

```typescript
const ALLOWED_PROTOCOLS = ['http:', 'https:']
const BLOCKED_HOSTS = ['localhost', '127.0.0.1', '0.0.0.0', '::1']

function validateWebViewUrl(urlString: string): void {
  // Step 1: Try to parse as URL
  let url: URL
  try {
    url = new URL(urlString)
  } catch {
    throw new Error(`Invalid URL: ${urlString}`)
  }

  // Step 2: Check protocol is safe
  if (!ALLOWED_PROTOCOLS.includes(url.protocol)) {
    throw new Error(`Blocked URL protocol: ${url.protocol}. Only http and https are allowed.`)
  }

  // Step 3: Block localhost addresses
  if (BLOCKED_HOSTS.includes(url.hostname)) {
    throw new Error(`Blocked URL host: ${url.hostname}. Localhost is not allowed for security reasons.`)
  }

  // Step 4: Block private IP ranges
  const ipMatch = url.hostname.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)
  if (ipMatch) {
    const [, a, b] = ipMatch.map(Number)
    // Check for private ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) {
      throw new Error(`Blocked private IP: ${url.hostname}. Private IP addresses are not allowed for security reasons.`)
    }
  }
}
```

## Integration Points

### 1. Tab Creation (TabsContext.tsx)

When a user creates a new WebView tab, the URL is validated immediately:

```typescript
const createWebViewTab = useCallback((url: string, title?: string): Tab => {
  // Validate URL before creating the webview
  validateWebViewUrl(url)

  const tabId = generateTabId()
  const paneId = generatePaneId()
  const webViewPane = createWebViewPane(paneId, title ?? 'Web', url)
  const newTab: Tab = {
    id: tabId,
    title: title ?? new URL(url).hostname,
    root: webViewPane,
    isActive: true,
    order: tabs.length,
    isPinned: false,
  }
  setTabs((prev) => [...prev.map(t => ({ ...t, isActive: false })), newTab])
  setActiveTabId(newTab.id)
  setActivePaneId(paneId)
  return newTab
}, [tabs.length])
```

**Security Benefit**: Prevents creation of tabs with malicious URLs like:
- `javascript:alert('XSS')`
- `data:text/html,<script>alert('XSS')</script>`
- `http://localhost:3000/admin` (prevents access to local services)

### 2. Pane Splitting (TabsContext.tsx)

When splitting a pane with a WebView, the URL is validated:

```typescript
const splitPaneWithWebview = useCallback((paneId: string, direction: SplitDirection, url: string, title?: string) => {
  // Validate URL before creating the webview
  validateWebViewUrl(url)

  setTabs((prev) =>
    prev.map((tab) => {
      if (!tab.isActive) return tab

      const paneToSplit = findPane(tab.root, paneId)
      if (!paneToSplit || !isContentPane(paneToSplit)) return tab

      const newPane = createWebViewPane(
        generatePaneId(),
        title ?? new URL(url).hostname,
        url
      )

      const newSplit = createSplitPane(
        generatePaneId(),
        direction,
        { ...paneToSplit, isActive: false },
        newPane,
        0.5
      )

      const newRoot = replacePane(tab.root, paneId, newSplit)
      setActivePaneId(newPane.id)

      return { ...tab, root: newRoot }
    })
  )
}, [])
```

**Security Benefit**: Prevents splitting panes with untrusted URLs.

### 3. Session Recovery (TabsContext.tsx)

When restoring a saved session from localStorage, URLs are validated:

```typescript
function deserializePane(serialized: SerializedPane, idGenerator: () => string): PaneNode {
  switch (serialized.type) {
    case 'webview': {
      const url = serialized.url || 'about:blank'
      // Validate URL from stored session to prevent XSS from corrupted/malicious storage
      if (url !== 'about:blank') {
        try {
          validateWebViewUrl(url)
        } catch (error) {
          console.error('[Tabs] Invalid stored URL, using about:blank:', error)
          return createWebViewPane(idGenerator(), serialized.title || 'Web', 'about:blank')
        }
      }
      return createWebViewPane(idGenerator(), serialized.title || 'Web', url)
    }
    // ... other cases
  }
}
```

**Security Benefit**: Protects against corrupted or maliciously modified localStorage that could have XSS payloads.

### 4. User Navigation (WebViewPane.tsx)

When a user enters a URL and navigates, validation happens before any network request:

```typescript
const handleNavigate = useCallback(async (input: string) => {
  const trimmed = input.trim()
  if (!trimmed) return

  let normalizedUrl: string

  // Check if it looks like a URL
  const looksLikeUrl = /^(https?:\/\/)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(\/.*)?$/.test(trimmed) ||
                       trimmed.startsWith('http://') ||
                       trimmed.startsWith('https://') ||
                       trimmed.includes('localhost')

  if (looksLikeUrl) {
    // It's a URL - add https:// if missing
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      normalizedUrl = 'https://' + trimmed
    } else {
      normalizedUrl = trimmed
    }
  } else {
    // It's a search query - use Google
    normalizedUrl = `https://www.google.com/search?q=${encodeURIComponent(trimmed)}`
  }

  // Validate the URL before navigating
  try {
    validateWebViewUrl(normalizedUrl)
  } catch (err) {
    console.error('[WebViewPane] URL validation failed:', err)
    setError(String(err))
    setIsLoading(false)
    return
  }

  setCurrentUrl(normalizedUrl)
  setInputUrl(normalizedUrl)
  setIsLoading(true)
  setError(null)

  try {
    await invoke('navigate_webview', {
      webviewId: webviewId.current,
      url: normalizedUrl,
    })
    setIsLoading(false)
  } catch (err) {
    console.error('Failed to navigate:', err)
    setError(String(err))
    setIsLoading(false)
  }
}, [])
```

**Security Benefit**: Validates user input before navigating to prevent XSS attacks through URL bar manipulation.

## Attack Scenarios Prevented

### Scenario 1: Direct XSS Attack

**Attack**: User enters `javascript:alert('Hacked!')`

**Result**:
```
[WebViewPane] URL validation failed: Error: Blocked URL protocol: javascript:. Only http and https are allowed.
Error displayed to user: "Blocked URL protocol: javascript:. Only http and https are allowed."
Navigation prevented
```

### Scenario 2: Data URI Attack

**Attack**: User enters malicious data URI with embedded JavaScript
```
data:text/html,<script>// steal cookies</script>
```

**Result**:
```
[WebViewPane] URL validation failed: Error: Blocked URL protocol: data:. Only http and https are allowed.
```

### Scenario 3: SSRF Attack - Access Localhost

**Attack**: User enters `http://localhost:3000/admin`

**Result**:
```
[WebViewPane] URL validation failed: Error: Blocked URL host: localhost. Localhost is not allowed for security reasons.
```

Prevents accessing internal services like:
- `http://127.0.0.1:8080` (development servers)
- `http://localhost:3306` (databases)
- `http://0.0.0.0:9200` (search engines)

### Scenario 4: Private IP Access

**Attack**: User enters `http://192.168.1.1`

**Result**:
```
[WebViewPane] URL validation failed: Error: Blocked private IP: 192.168.1.1. Private IP addresses are not allowed for security reasons.
```

Prevents SSRF attacks against:
- Class A: `10.0.0.0/8`
- Class B: `172.16.0.0/12`
- Class C: `192.168.0.0/16`

### Scenario 5: Corrupted Storage

**Attack**: Malicious process modifies localStorage to inject XSS URL

**Session data** (corrupted):
```json
{
  "version": 1,
  "tabs": [
    {
      "title": "Compromised",
      "root": {
        "type": "webview",
        "url": "javascript:alert('XSS from storage')"
      }
    }
  ]
}
```

**Result**:
```
[Tabs] Invalid stored URL, using about:blank: Error: Blocked URL protocol: javascript:. Only http and https are allowed.
```

Session is safely restored with `about:blank` instead of the malicious URL.

## Security Validation Flow

```
┌─────────────────────────────────┐
│ User Input / System Event       │
│ (Create Tab, Navigate, etc.)    │
└────────────────┬────────────────┘
                 │
                 ▼
         ┌───────────────┐
         │ Normalize URL │
         │ (add https://) │
         └───────┬───────┘
                 │
                 ▼
      ┌──────────────────────┐
      │ validateWebViewUrl() │
      └────────┬─────────────┘
               │
         ┌─────┴──────┬──────────┬──────────┬──────────┐
         │            │          │          │          │
         ▼            ▼          ▼          ▼          ▼
    ┌────────┐  ┌─────────┐  ┌──────┐  ┌─────────┐  ┌────────────┐
    │ Valid  │  │Protocol │  │localhost│Private│  │File:// etc │
    │ URL?   │  │http/s?  │  │Blocked? │IP?     │  │Blocked?    │
    └────────┘  └─────────┘  └──────┘  └─────────┘  └────────────┘
         │          │           │        │          │
         └──────────┴───────────┴────────┴──────────┘
                    │
        ┌───────────┴────────────┐
        │                        │
        ▼                        ▼
   ┌──────────┐          ┌─────────────┐
   │Validation│          │    Throw    │
   │ Passes   │          │    Error    │
   └────┬─────┘          └──────┬──────┘
        │                       │
        ▼                       ▼
   ┌──────────────┐      ┌─────────────────┐
   │ Proceed with │      │ Display Error & │
   │ Navigation   │      │ Prevent Action  │
   └──────────────┘      └─────────────────┘
```

## Code Files Modified

1. **`/src/contexts/TabsContext.tsx`** (102 lines added)
   - `validateWebViewUrl()` function
   - Updated `createWebViewTab()`
   - Updated `splitPaneWithWebview()`
   - Updated `deserializePane()`

2. **`/src/components/WebViewPane.tsx`** (46 lines added)
   - `validateWebViewUrl()` function
   - Updated `handleNavigate()`

## Summary

The security implementation follows defense-in-depth principles with validation at:
1. **Tab Creation** - Prevents malicious tabs from being created
2. **Pane Operations** - Prevents malicious WebView panes
3. **Session Recovery** - Prevents loading corrupted/malicious stored sessions
4. **User Navigation** - Prevents XSS via URL bar input

All validation failures are logged with component prefixes for easy debugging (`[WebViewPane]`, `[Tabs]`) and provide clear error messages to users.
