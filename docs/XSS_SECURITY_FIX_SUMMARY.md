# WebView XSS Security Fix - Implementation Summary

## Overview

Fixed critical XSS (Cross-Site Scripting) vulnerabilities in WebView URL handling by implementing strict URL validation that prevents dangerous protocols and private IP ranges from being loaded.

## Vulnerabilities Addressed

1. **Protocol-based XSS**: Blocked dangerous protocols like `javascript:`, `data:`, and `file:` that could execute arbitrary code
2. **SSRF (Server-Side Request Forgery)**: Blocked localhost and private IP addresses that could access internal services
3. **Malicious Stored Sessions**: Validated URLs restored from localStorage to prevent loading malicious content from corrupted storage

## Implementation Details

### 1. URL Validation Function

Added `validateWebViewUrl()` function in both files:
- `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/TabsContext.tsx`
- `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/components/WebViewPane.tsx`

**Validation Rules:**
- Only allows `http://` and `https://` protocols
- Blocks localhost addresses: `localhost`, `127.0.0.1`, `0.0.0.0`, `::1`
- Blocks private IP ranges:
  - `10.0.0.0/8` (Class A private)
  - `172.16.0.0/12` (Class B private)
  - `192.168.0.0/16` (Class C private)

**Sample Code:**
```typescript
const ALLOWED_PROTOCOLS = ['http:', 'https:']
const BLOCKED_HOSTS = ['localhost', '127.0.0.1', '0.0.0.0', '::1']

function validateWebViewUrl(urlString: string): void {
  let url: URL
  try {
    url = new URL(urlString)
  } catch {
    throw new Error(`Invalid URL: ${urlString}`)
  }

  // Only allow http/https protocols
  if (!ALLOWED_PROTOCOLS.includes(url.protocol)) {
    throw new Error(`Blocked URL protocol: ${url.protocol}. Only http and https are allowed.`)
  }

  // Block localhost
  if (BLOCKED_HOSTS.includes(url.hostname)) {
    throw new Error(`Blocked URL host: ${url.hostname}. Localhost is not allowed for security reasons.`)
  }

  // Block private IP ranges
  const ipMatch = url.hostname.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)
  if (ipMatch) {
    const [, a, b] = ipMatch.map(Number)
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) {
      throw new Error(`Blocked private IP: ${url.hostname}. Private IP addresses are not allowed for security reasons.`)
    }
  }
}
```

### 2. Validation Points in TabsContext.tsx

#### A. createWebViewTab() - Tab Creation
Validates URL before creating a new WebView tab:
```typescript
const createWebViewTab = useCallback((url: string, title?: string): Tab => {
  validateWebViewUrl(url)  // Validate first
  // ... rest of implementation
}, [tabs.length])
```

#### B. splitPaneWithWebview() - Pane Splitting
Validates URL before splitting pane with WebView:
```typescript
const splitPaneWithWebview = useCallback((paneId: string, direction: SplitDirection, url: string, title?: string) => {
  validateWebViewUrl(url)  // Validate first
  // ... rest of implementation
}, [])
```

#### C. deserializePane() - Session Recovery
Validates URLs loaded from localStorage to prevent malicious stored sessions:
```typescript
case 'webview': {
  const url = serialized.url || 'about:blank'
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
```

### 3. Validation in WebViewPane.tsx

#### handleNavigate() - Navigation Handler
Validates URL before navigating to prevent dynamic XSS from user input:
```typescript
const handleNavigate = useCallback(async (input: string) => {
  // ... URL normalization logic ...

  // Validate the URL before navigating
  try {
    validateWebViewUrl(normalizedUrl)
  } catch (err) {
    console.error('[WebViewPane] URL validation failed:', err)
    setError(String(err))
    setIsLoading(false)
    return
  }

  // ... proceed with navigation ...
}, [])
```

## Security Benefits

1. **Prevents XSS Attacks**: Users cannot load `javascript:` URLs that execute arbitrary code
2. **Prevents Data URIs**: Blocks `data:` URIs that could contain inline HTML/JavaScript
3. **Prevents File Access**: Blocks `file://` URLs that could access local file system
4. **Prevents SSRF**: Blocks internal IP addresses and localhost that could be used to attack internal services
5. **Protects Against Corrupted Storage**: Validates URLs from localStorage to ensure they weren't tampered with

## Testing Recommendations

### Test Cases to Verify

1. **Valid URLs Work:**
   - `https://www.google.com` (should work)
   - `http://example.com` (should work)
   - `https://api.example.com/path?query=value` (should work)

2. **Dangerous Protocols Blocked:**
   - `javascript:alert('XSS')` (should fail with "Blocked URL protocol")
   - `data:text/html,<script>alert('XSS')</script>` (should fail)
   - `file:///etc/passwd` (should fail)

3. **Localhost Blocked:**
   - `http://localhost:3000` (should fail with "Blocked URL host")
   - `http://127.0.0.1:3000` (should fail)
   - `http://0.0.0.0:8080` (should fail)

4. **Private IPs Blocked:**
   - `http://10.0.0.1` (should fail with "Blocked private IP")
   - `http://192.168.1.1` (should fail)
   - `http://172.16.0.1` (should fail)

5. **Public IPs Work:**
   - `https://8.8.8.8` (should work - public IP)
   - `https://1.1.1.1` (should work - public IP)

### Error Handling Verification

Ensure error messages are:
- Displayed to users in WebViewPane error UI
- Logged with `[WebViewPane]` or `[Tabs]` prefix for debugging
- Specific about what validation failed

## Files Modified

1. `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/TabsContext.tsx`
   - Added `validateWebViewUrl()` function
   - Updated `createWebViewTab()` to validate URLs
   - Updated `splitPaneWithWebview()` to validate URLs
   - Updated `deserializePane()` to validate stored URLs
   - Removed unused `useRef` import

2. `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/components/WebViewPane.tsx`
   - Added `validateWebViewUrl()` function
   - Updated `handleNavigate()` to validate user-entered URLs

## Side Effects and Considerations

1. **User Experience Impact**: If users have valid localhost URLs saved, they will need to be removed or external URLs used
2. **Development Workflow**: Local development WebViews must use public IPs or external tunnel services
3. **Error Messages**: Clear error messages help users understand why a URL was blocked

## Future Improvements

1. **Configurable Whitelist**: Allow administrators to whitelist specific domains
2. **URL Rewriting**: Auto-redirect localhost to tunnel services for development
3. **Content Security Policy (CSP)**: Add CSP headers to Tauri webview configuration
4. **Sandbox Mode**: Run WebViews in more restricted sandbox with minimal permissions

## Security Audit Notes

This fix addresses OWASP Top 10 vulnerabilities:
- **A03:2021 - Injection**: Prevented code injection via URL protocols
- **A06:2021 - Vulnerable and Outdated Components**: Improved input validation

The implementation follows defense-in-depth principles with validation at multiple entry points (creation, splitting, navigation, and storage recovery).
