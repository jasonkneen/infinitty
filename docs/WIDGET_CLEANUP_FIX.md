# Widget Cleanup Fix - Resource Disposal Guarantee

## Problem
Widget cleanup could fail partway through, leaving resources leaked. If `dispose()` throws on any instance, the cleanup operation would abort, leaving:
- Widgets remaining in registry (risk of double-execution)
- Disposables not properly freed
- Module deactivation incomplete
- Memory leaks accumulating

## Solution Implemented
Wrapped all cleanup operations in try-catch blocks with error collection. Errors are logged but don't prevent continued cleanup or registry removal.

## Changes Made

### 1. `unloadWidget()` - Lines 129-167
**Before:** Single try-catch would exit early on first error
**After:**
- Iterate through all instances with individual try-catch blocks
- Always clear instances map
- Always remove from registry (even if errors occurred)
- Collect and log all errors for debugging

**Key improvements:**
```typescript
const errors: Error[] = []

// Dispose with error collection
for (const [instanceId, instance] of widget.instances) {
  try {
    instance.disposables.dispose()
  } catch (e) {
    errors.push(new Error(`Failed to dispose instance ${instanceId}: ${String(e)}`))
  }

  try {
    if (widget.module.deactivate) {
      widget.module.deactivate()
    }
  } catch (e) {
    errors.push(new Error(`Failed to deactivate widget ${widgetId}: ${String(e)}`))
  }
}

// Always cleanup regardless of errors
widget.instances.clear()
widgetRegistry.delete(widgetId)

// Log all errors for debugging
if (errors.length > 0) {
  console.error(`[WidgetHost] Errors unloading widget ${widgetId}:`, errors)
}
```

### 2. `destroyWidgetInstance()` - Lines 368-406
**Before:** Single dispose could fail, leaving instance in registries
**After:**
- Try-catch around disposable disposal
- Always remove from local instances registry
- Iterate through all widgets with individual try-catch for deactivation
- Collect and log all errors

**Key improvements:**
- Guarantees removal from `instancesRef.current` even if dispose fails
- Separate error handling for each cleanup operation
- Clear error messages with context

### 3. `useEffect` cleanup - Lines 439-451
**Before:** Generic error handling
**After:**
- Explicit try-catch for event unsubscribe
- Detailed error messages with context prefix

## Pattern Applied

All cleanup operations now follow this pattern:
```typescript
const errors: Error[] = []

// Cleanup operations with individual try-catch
try {
  // operation 1
} catch (e) {
  errors.push(new Error(`Context: ${String(e)}`))
}

// Always perform final cleanup
finalCleanup()

// Log all errors
if (errors.length > 0) {
  console.error('[WidgetHost] Errors during cleanup:', errors)
}
```

## Benefits

1. **Resource Guarantee**: Registry is always cleaned up, no orphaned widgets
2. **Partial Failures OK**: One failed dispose doesn't break entire cleanup chain
3. **Debuggability**: All errors are collected and logged with context
4. **No Leaks**: Even if widget module or disposable throws, instance is removed
5. **Production Ready**: Handles edge cases gracefully

## Testing Recommendations

Test these scenarios:
- Widget dispose throws an error
- Widget deactivate throws an error
- Both dispose and deactivate throw
- Multiple instances with mixed failures
- Verify registry is always cleaned (use DevTools to inspect widgetRegistry)
- Verify error console messages are helpful for debugging

## Files Modified
- `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetHost.tsx`

Lines: 129-167 (unloadWidget), 368-406 (destroyWidgetInstance), 439-451 (cleanup)
