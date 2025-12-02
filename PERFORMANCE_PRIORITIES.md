# Performance Optimization Priorities

## Overview

This document provides a prioritized action plan for addressing the 15 performance issues identified in the hybrid-terminal analysis.

---

## Priority Matrix

### Tier 1: CRITICAL - Fix First (Blocks rendering, memory leaks)

#### Issue #1: Unbounded Block Storage
- **Status:** Not started
- **Effort:** 15 minutes
- **Impact:** 60% memory reduction
- **File:** `src/hooks/useBlockTerminal.ts` (line 13)
- **Action:** Reduce MAX_BLOCKS from 500 to 200, fix eviction logic
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Create 500+ blocks in a session
  - Verify old blocks are evicted
  - Check memory doesn't grow beyond ~2MB

#### Issue #2: BlocksView Virtualization Math Bug
- **Status:** Not started
- **Effort:** 10 minutes
- **Impact:** Correct virtualization behavior
- **File:** `src/components/BlocksView.tsx` (line 83-93)
- **Action:** Remove duplicate loop, simplify cumulative height calculation
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Scroll through 200+ blocks
  - Verify all blocks render correctly
  - Check no visible gaps or overlaps

---

### Tier 2: HIGH - Fix Next (Re-render cascades, event leaks)

#### Issue #3: Missing Memoization on Heavy Children
- **Status:** Not started
- **Effort:** 20 minutes
- **Impact:** 40% fewer re-renders during typing
- **File:** `src/components/TerminalPane.tsx` (line 28)
- **Action:** Wrap BlocksView and WarpInput with React.memo
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Profile with React DevTools
  - Type in WarpInput and verify BlocksView doesn't re-render
  - Check Profiler shows memoization working

#### Issue #4: Event Listener Churn in App.tsx
- **Status:** Not started
- **Effort:** 30 minutes
- **Impact:** Reduced event listener memory/CPU
- **File:** `src/App.tsx` (line 156-226)
- **Action:** Reorganize keyboard handler, reduce dependency count
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - All keyboard shortcuts still work
  - No console errors
  - Memory profile shows fewer listeners

#### Issue #5: SplitPane Resize Handle Event Churn
- **Status:** Not started
- **Effort:** 25 minutes
- **Impact:** Smoother resizing, less CPU during drag
- **File:** `src/components/SplitPane.tsx` (line 35-63)
- **Action:** Simplify useEffect deps, add passive listeners
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Resize splits multiple times
  - Profile CPU usage during resize
  - Verify smooth 60fps operation

#### Issue #6: WidgetPane Inline Functions
- **Status:** Not started
- **Effort:** 20 minutes
- **Impact:** Reduced GC pressure with multiple widgets
- **File:** `src/components/WidgetPane.tsx` (line 108-115)
- **Action:** Extract inline callbacks to useCallback
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Create 10+ widgets
  - Profile memory/CPU
  - Check no new function allocations per render

---

### Tier 3: MEDIUM - Fix After Tier 2 (Optimization tweaks)

#### Issue #7: Terminal Re-initialization
- **Status:** Not started
- **Effort:** 25 minutes
- **Impact:** Terminal persists across re-renders
- **File:** `src/hooks/useTerminal.ts` (line 85-132)
- **Action:** Stabilize options ref, prevent re-initialization
- **Blocker:** No - can implement after #3
- **Dependencies:** None (but good to do with #3)
- **Testing:**
  - Terminal output persists on parent re-render
  - Settings changes don't reset terminal
  - Cursor position maintained

#### Issue #8: BlocksView Scroll State Batching
- **Status:** Not started
- **Effort:** 15 minutes
- **Impact:** 60% fewer state updates during scroll
- **File:** `src/components/BlocksView.tsx` (line 168-182)
- **Action:** Combine 3 setState calls into 1
- **Blocker:** No - depends on #2 for testing
- **Dependencies:** Issue #2 (for accurate testing)
- **Testing:**
  - Fast scroll through blocks
  - Profile shows ~60 updates/sec instead of 180+
  - No jank during fast scroll

#### Issue #9: ResizeObserver Debouncing
- **Status:** Not started
- **Effort:** 20 minutes
- **Impact:** No jank during window resize
- **File:** `src/components/BlocksView.tsx` (line 185-197)
- **Action:** Add RAF debouncing to resize handler
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Drag window edge to resize
  - Profile CPU during resize (should drop 40-50%)
  - No stutter or frame drops

#### Issue #10: WarpInput Model Fetching Cache
- **Status:** Not started
- **Effort:** 20 minutes
- **Impact:** Prevents duplicate API calls
- **File:** `src/components/WarpInput.tsx` (line 117-132)
- **Action:** Use ref-based caching instead of state checking
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Switch to OpenCode provider multiple times
  - Network tab shows only 1 API call (not repeated)
  - Models load correctly

#### Issue #11: Commands Array Memoization
- **Status:** Not started
- **Effort:** 5 minutes
- **Impact:** Trivial (but correct pattern)
- **File:** `src/App.tsx` (line 80-154)
- **Action:** Wrap commands array in useMemo
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - CommandPalette opens and works
  - Shortcuts are accessible

#### Issue #12: Relative Time Memoization
- **Status:** Not started
- **Effort:** 10 minutes
- **Impact:** Minor (reduced Date allocations)
- **File:** `src/components/BlocksView.tsx` (line 10-25)
- **Action:** Use Date.now(), memoize time strings
- **Blocker:** No - can implement independently
- **Dependencies:** None
- **Testing:**
  - Time strings display correctly
  - Profile shows fewer allocations

---

### Tier 4: LOW - Nice to Have (Code quality)

#### Issue #13: TabsContext Callback Dependencies
- **Status:** Not started
- **Effort:** 30 minutes (analysis heavy)
- **Impact:** Prevents downstream re-renders
- **File:** `src/contexts/TabsContext.tsx` (line 200+)
- **Action:** Audit all callbacks, stabilize dependencies
- **Blocker:** Yes - requires deep analysis first
- **Dependencies:** None
- **Testing:**
  - All tab operations work correctly
  - No performance regressions

#### Issue #14: Inline Styles → CSS Modules
- **Status:** Not started
- **Effort:** 4+ hours (large refactor)
- **Impact:** Code maintainability, minor perf
- **File:** Multiple components
- **Action:** Extract all inline styles to CSS/Tailwind
- **Blocker:** No - can do piecemeal
- **Dependencies:** None (but optional)
- **Testing:**
  - Visual regression testing
  - Build size comparison

#### Issue #15: Dependency Array Audit
- **Status:** Not started
- **Effort:** 2+ hours (audit all useEffects)
- **Impact:** Code correctness
- **File:** Various components
- **Action:** Audit all useEffect dependencies
- **Blocker:** No - ongoing maintenance
- **Dependencies:** None
- **Testing:**
  - No console warnings
  - Behavior unchanged

---

## Implementation Timeline

### Week 1: Critical Path (Tier 1)
- **Monday:** Issue #1 + #2 (Block storage + virtualization)
- **Time Required:** 30 minutes
- **Testing Time:** 20 minutes
- **Expected Result:** Memory usage drops 60%, smooth scrolling

### Week 2: High Impact (Tier 2)
- **Monday:** Issue #3 (Memoization)
- **Tuesday:** Issue #4 + #5 (Event listeners)
- **Wednesday:** Issue #6 (WidgetPane)
- **Time Required:** 90 minutes total
- **Testing Time:** 40 minutes
- **Expected Result:** 40-50% fewer re-renders

### Week 3: Medium Priority (Tier 3)
- **Monday:** Issue #7 (Terminal)
- **Tuesday:** Issue #8 + #9 (Scroll/Resize)
- **Wednesday:** Issue #10, #11, #12 (Caching/Memoization)
- **Time Required:** 90 minutes total
- **Testing Time:** 30 minutes
- **Expected Result:** Smooth interactions, no jank

### Week 4+: Maintenance (Tier 4)
- **Ongoing:** Issue #13 (Callback audit)
- **Backlog:** Issue #14 (CSS refactor)
- **Continuous:** Issue #15 (Dependency audit)

---

## Validation Criteria

### After Tier 1 (Critical)
- [ ] No memory growth beyond 2MB for 100-block session
- [ ] Scroll performance is smooth (60fps)
- [ ] No console errors related to virtualization

### After Tier 2 (High)
- [ ] BlocksView doesn't re-render on WarpInput changes
- [ ] Event listener count stable (not growing)
- [ ] Window resize doesn't cause jank

### After Tier 3 (Medium)
- [ ] Terminal persists on parent re-render
- [ ] Scroll updates batched to 60/sec max
- [ ] ResizeObserver CPU < 15% during resize
- [ ] API calls cached (no duplicates)

### Overall Success
- [ ] Memory profile: 60% improvement
- [ ] Re-render count: 60% reduction
- [ ] Frame rate: Stable 55-60fps
- [ ] CPU usage: 40-50% improvement
- [ ] No console errors or warnings
- [ ] All functionality preserved

---

## Risk Assessment

| Issue | Risk | Mitigation |
|-------|------|-----------|
| #1 Block eviction | LOW | Could lose recent history | Add undo/recovery |
| #2 Virtualization | LOW | Could break rendering | Visual regression test |
| #3 Memoization | VERY LOW | Shallow compare issues | Add custom comparator if needed |
| #4 Keyboard handler | LOW | Could break shortcuts | Test all 14 shortcuts |
| #5 Resize handle | LOW | Resize becomes unresponsive | Test drag to extremes |
| #6 WidgetPane | VERY LOW | Callbacks fire at wrong time | Test widget interactions |
| #7 Terminal | MEDIUM | Terminal state lost | Verify persistence works |
| #8 Scroll batching | LOW | Virtualization out of sync | Test fast scroll |
| #9 Resize debounce | LOW | RAF not supported (old browser) | Add polyfill check |
| #10 Cache | LOW | Stale data | Add cache invalidation |
| #11 Commands memo | VERY LOW | Command list breaks | Test command palette |
| #12 Time memo | VERY LOW | None | Test time display |
| #13 Callbacks | MEDIUM | Could break if not audited carefully | Review each change |
| #14 CSS refactor | LOW | Visual regressions | Comprehensive testing |
| #15 Audit | LOW | None | Preventive only |

---

## Success Metrics

### Memory
- Current: ~5MB for 100 blocks
- Target: ~2MB for 100 blocks
- Method: Chrome DevTools → Memory tab

### Re-renders
- Current: 50-180/sec during interaction
- Target: 20-60/sec during interaction
- Method: React DevTools → Profiler tab

### Frame Rate
- Current: 30-50fps during scroll/interaction
- Target: 55-60fps consistently
- Method: Chrome DevTools → Performance tab

### CPU Usage
- Current: 25-50% during interaction
- Target: 8-20% during interaction
- Method: Chrome DevTools → Performance tab

### User Experience
- Scroll should be silky smooth
- Typing should have no lag
- Window resize should not stutter
- Terminal should remain responsive

---

## Questions to Answer Before Starting

1. **Which issues are blockers for other features?**
   - Yes, Issue #7 (Terminal) is needed for stable terminal persistence

2. **Are there any architectural decisions that might affect these fixes?**
   - Consider if TabsContext should be replaced with Zustand
   - Consider if state management could be simplified

3. **Should we profile first to confirm issues?**
   - Yes - get baseline metrics before implementing fixes
   - Profile after each tier to verify improvements

4. **What's the acceptable regression risk?**
   - Very low - all fixes should be pure optimizations
   - Functionality should remain 100% identical

---

## Next Steps

1. **Baseline profiling** (1 hour)
   - Memory: Take heap snapshot at rest
   - Re-renders: Profile 30-second interaction session
   - CPU: Record performance during typical workflow

2. **Implement Tier 1** (1 hour)
   - Fix #1: Block eviction
   - Fix #2: Virtualization math

3. **Verify improvements** (30 minutes)
   - Re-profile with same methodology
   - Compare metrics against baseline

4. **Continue to Tier 2**
   - Repeat cycle for each tier
   - Track cumulative improvements

---

## Documentation

All fixes have detailed before/after code in:
- `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/PERFORMANCE_FIXES_GUIDE.md`

All issues with context in:
- `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/PERFORMANCE_ANALYSIS.md`

---

## Final Notes

This is a comprehensive roadmap, not a mandate. Prioritize based on:
1. **User-facing impact** (Tier 1-2)
2. **Available time** (can chip away at Tier 3-4)
3. **Team bandwidth** (involves others for reviews)
4. **Risk tolerance** (prefer low-risk fixes first)

The critical path is Tier 1 + Tier 2, which can be completed in 2-3 days of focused work.
