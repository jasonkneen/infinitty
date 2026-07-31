import AppKit

enum PaneLog {
    private static let url = URL(fileURLWithPath: "/tmp/infinitty-pane.log")
    private static let queue = DispatchQueue(label: "infinitty.pane-log")

    static func log(_ message: String) {
        let line = "[\(ProcessInfo.processInfo.systemUptime)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func describe(_ view: NSView) -> String {
        if let split = view as? NSSplitView {
            let axis = split.isVertical ? "V" : "H"
            return "\(axis)[\(split.arrangedSubviews.map(describe).joined(separator: ","))]"
        }
        if let terminal = view as? TerminalView {
            return "terminal(\(ObjectIdentifier(terminal)),\(NSStringFromRect(terminal.frame)),"
                + "hidden=\(terminal.isHiddenOrHasHiddenAncestor),alpha=\(terminal.alphaValue))"
        }
        if let utility = view as? UtilityPaneView {
            return "\(utility.kind.title.lowercased())(\(ObjectIdentifier(utility)),"
                + "\(NSStringFromRect(utility.frame)),hidden=\(utility.isHiddenOrHasHiddenAncestor),"
                + "alpha=\(utility.alphaValue))"
        }
        let children = view.subviews.map(describe).joined(separator: ",")
        return children.isEmpty
            ? "view(\(ObjectIdentifier(view)))"
            : "view(\(ObjectIdentifier(view))){\(children)}"
    }
}

enum PaneMetrics {
    static let leadingInset: CGFloat = 8
    static let trailingInset: CGFloat = 8
    static let internalHorizontalInset: CGFloat = 2
    static let topInset: CGFloat = 3
    static let bottomInset: CGFloat = 8
    static let internalVerticalInset: CGFloat = 2
    static let horizontalCanvasInset: CGFloat = 0
    static let cornerRadius: CGFloat = 10
    static let minimumTerminalContentInset: CGFloat = 15

    static func terminalContentInset(configured: CGFloat) -> CGFloat {
        max(configured, minimumTerminalContentInset)
    }
}

/// Pane dividers are geometry handles only. Painting their native black rule
/// breaks the window's one continuous tinted surface.
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

extension NSView {
    func paneHorizontalInsets() -> (leading: CGFloat, trailing: CGFloat) {
        (
            paneHasHorizontalNeighbor(onRight: false)
                ? PaneMetrics.internalHorizontalInset : PaneMetrics.leadingInset,
            paneHasHorizontalNeighbor(onRight: true)
                ? PaneMetrics.internalHorizontalInset : PaneMetrics.trailingInset
        )
    }

    private func paneHasHorizontalNeighbor(onRight: Bool) -> Bool {
        var branch: NSView = self
        var ancestor = superview
        while let parent = ancestor {
            if let split = parent as? NSSplitView, split.isVertical,
               let index = split.arrangedSubviews.firstIndex(of: branch) {
                if onRight ? index < split.arrangedSubviews.count - 1 : index > 0 {
                    return true
                }
            }
            branch = parent
            ancestor = parent.superview
        }
        return false
    }

    /// Outer window edges keep their larger top/bottom breathing room, while
    /// vertically adjacent tiles contribute only 2pt each to their shared gap.
    func paneVerticalInsets() -> (top: CGFloat, bottom: CGFloat) {
        (
            paneHasVerticalNeighbor(above: true)
                ? PaneMetrics.internalVerticalInset : PaneMetrics.topInset,
            paneHasVerticalNeighbor(above: false)
                ? PaneMetrics.internalVerticalInset : PaneMetrics.bottomInset
        )
    }

    private func paneHasVerticalNeighbor(above: Bool) -> Bool {
        var branch: NSView = self
        var ancestor = superview
        while let parent = ancestor {
            if let split = parent as? NSSplitView, !split.isVertical,
               let index = split.arrangedSubviews.firstIndex(of: branch) {
                // Horizontal NSSplitView order is visual top-to-bottom, even
                // though the split view itself is flipped.
                if above ? index > 0 : index < split.arrangedSubviews.count - 1 {
                    return true
                }
            }
            branch = parent
            ancestor = parent.superview
        }
        return false
    }

    /// Portion covered by a transparent full-size titlebar. Normally zero
    /// below horizontal tabs; nonzero when side tabs extend panes to the top.
    func paneTopObstructionPoints() -> CGFloat {
        guard let window, window.styleMask.contains(.fullSizeContentView) else { return 0 }
        var ancestor = superview
        while let view = ancestor {
            if let chrome = view as? TerminalChromeView, !chrome.sideTabs { return 0 }
            ancestor = view.superview
        }
        let layoutRect = convert(window.contentLayoutRect, from: nil)
        return max(bounds.height - layoutRect.maxY, 0)
    }
}

enum PaneDropZone: CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom
    case center

    static func resolve(point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        let edge: CGFloat = 0.25
        if x < edge { return .left }
        if x > 1 - edge { return .right }
        if y < edge { return .bottom }
        if y > 1 - edge { return .top }
        return .center
    }

    func previewFrame(in bounds: NSRect) -> NSRect {
        switch self {
        case .left:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .right:
            return NSRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .top:
            return NSRect(x: bounds.minX, y: bounds.midY,
                          width: bounds.width, height: bounds.height / 2)
        case .bottom:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: bounds.height / 2)
        case .center:
            return bounds
        }
    }
}

/// A serializable-in-spirit snapshot of the live AppKit split tree. Runtime
/// layout remains native NSSplitView so divider dragging stays fluid, while
/// tests and drag operations get one stable vocabulary for the topology.
indirect enum PaneLayoutNode: Equatable {
    case leaf(ObjectIdentifier)
    case split(vertical: Bool, children: [PaneLayoutNode])
}

/// A main tab stays open while any terminal or smart-pane leaf remains.
/// Terminal sessions are only one kind of leaf, so using their count here
/// would incorrectly close a Chat, Files, or Browser-only tab.
enum PaneLifecyclePolicy {
    static func shouldCloseTab(remainingPaneCount: Int) -> Bool {
        remainingPaneCount == 0
    }
}

enum PaneLayoutController {
    typealias DividerPositions = [(split: NSSplitView, positions: [CGFloat])]
    typealias DividerRatios = [(split: NSSplitView, ratios: [CGFloat])]

    static func snapshot(of view: NSView) -> PaneLayoutNode? {
        if view is TerminalView || view is UtilityPaneView {
            return .leaf(ObjectIdentifier(view))
        }
        if let split = view as? NSSplitView {
            let children = split.arrangedSubviews.compactMap(snapshot)
            guard !children.isEmpty else { return nil }
            return .split(vertical: split.isVertical, children: children)
        }
        let children = view.subviews.compactMap(snapshot)
        // A plain host is not itself a layout node. It may own exactly one
        // split/leaf root; returning the first of several branches would hide
        // the overlapping-root corruption this snapshot exists to diagnose.
        guard children.count == 1 else { return nil }
        return children[0]
    }

    /// A pane host is either empty or owns one complete split/leaf tree.
    /// Multiple direct layout children overlap because TerminalChromeView.body
    /// gives each root child the full content rectangle.
    static func rootInvariantHolds(in root: NSView) -> Bool {
        let children = layoutChildren(in: root)
        guard children.count <= 1 else { return false }
        guard let child = children.first else { return true }
        var leafIDs = Set<ObjectIdentifier>()
        return validBranch(child, leafIDs: &leafIDs)
    }

    /// Repair a legacy multi-root host by wrapping all existing branches in one
    /// split. Fresh mutations maintain the invariant directly; this path lets
    /// already-corrupted tabs recover without dropping any pane identity.
    @discardableResult
    static func normalizeRoot(in root: NSView) -> Bool {
        var changed = collapseRedundantSplits(in: root)
        let children = layoutChildren(in: root)
        guard children.count > 1 else {
            stabilizeRoot(in: root)
            return changed
        }

        let ordered = children.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: root)
            let right = rhs.convert(rhs.bounds, to: root)
            if abs(left.minX - right.minX) > 1 { return left.minX < right.minX }
            if abs(left.maxY - right.maxY) > 1 { return left.maxY > right.maxY }
            return root.subviews.firstIndex(of: lhs) ?? 0
                < root.subviews.firstIndex(of: rhs) ?? 0
        }
        let split = PaneSplitView(frame: usableBounds(of: root, fallback: root.bounds))
        split.isVertical = preferredRootAxis(for: ordered, in: root)
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        for child in ordered {
            child.removeFromSuperview()
            child.autoresizingMask = []
            split.addArrangedSubview(child)
        }
        root.addSubview(split)
        stabilizeRoot(in: root)
        equalize(split)
        root.layoutSubtreeIfNeeded()
        PaneLog.log(
            "root normalized branches=\(ordered.count) tree=\(PaneLog.describe(root))")
        changed = true
        return changed
    }

    /// Remove one pane leaf, collapse every now-redundant ancestor, and keep
    /// unaffected divider ratios. This is the sole structural destruction path
    /// for terminal and utility leaves.
    @discardableResult
    static func removeLeaf(_ leaf: NSView, from root: NSView) -> Bool {
        _ = normalizeRoot(in: root)
        // `false` is a fail-closed result: callers retain the pane's controller
        // and backing state. Refuse to mutate an already-invalid sibling tree,
        // otherwise the requested leaf could be gone before the postcondition
        // reports failure and the caller would retain a detached record.
        guard rootInvariantHolds(in: root) else {
            PaneLog.log(
                "ERROR remove invalid-root preflight leaf=\(ObjectIdentifier(leaf)) "
                    + "tree=\(PaneLog.describe(root))")
            return false
        }
        guard leaf === root || leaf.isDescendant(of: root),
              leaf is TerminalView || leaf is UtilityPaneView,
              let parent = leaf.superview else { return false }

        stabilizeRoot(in: root)
        let ratios = captureDividerRatios(in: root)
        if let split = parent as? NSSplitView {
            leaf.removeFromSuperview()
            collapseAncestors(startingAt: split, root: root)
        } else if parent === root {
            leaf.removeFromSuperview()
        } else {
            return false
        }

        _ = normalizeRoot(in: root)
        stabilizeRoot(in: root, restoring: ratios)
        let valid = rootInvariantHolds(in: root)
        if !valid {
            PaneLog.log(
                "ERROR remove invalid-root leaf=\(ObjectIdentifier(leaf)) "
                    + "tree=\(PaneLog.describe(root))")
        }
        return valid
    }

    /// Re-seat the one root branch and restore surviving split ratios after a
    /// frame change. It never reparents an individual nested leaf.
    static func stabilizeRoot(in root: NSView, restoring ratios: DividerRatios = []) {
        let children = layoutChildren(in: root)
        guard children.count <= 1 else { return }
        guard let child = children.first else {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            return
        }
        prepareFrameManaged(child, filling: usableBounds(of: root, fallback: child.frame))
        normalizeArrangedSubviewMasks(in: child)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        restoreDividerRatios(ratios)
        root.layoutSubtreeIfNeeded()
        repairDegenerateSplits(in: child)
        root.layoutSubtreeIfNeeded()
    }

    private static func layoutChildren(in root: NSView) -> [NSView] {
        // Do not use `snapshot != nil` as the membership test here. A corrupt
        // plain wrapper with two pane leaves deliberately has no snapshot; if
        // it were filtered out, an invalid overlapping subtree would look like
        // an empty (therefore valid) pane host and destruction could proceed.
        root.subviews.filter(containsLayoutLeaf)
    }

    /// True when `view` is, or recursively contains, a pane leaf. Destructive
    /// recovery paths use this instead of `snapshot(of:)`: a deliberately
    /// invalid plain wrapper has no snapshot but may still own live panes.
    static func containsLayoutLeaf(_ view: NSView) -> Bool {
        if view is TerminalView || view is UtilityPaneView {
            return true
        }
        return view.subviews.contains(where: containsLayoutLeaf)
    }

    private static func validBranch(
        _ view: NSView, leafIDs: inout Set<ObjectIdentifier>
    ) -> Bool {
        if view is TerminalView || view is UtilityPaneView {
            return leafIDs.insert(ObjectIdentifier(view)).inserted
        }
        guard let split = view as? NSSplitView,
              split.arrangedSubviews.count >= 2 else { return false }
        return split.arrangedSubviews.allSatisfy {
            validBranch($0, leafIDs: &leafIDs)
        }
    }

    private static func collapseAncestors(startingAt start: NSSplitView, root: NSView) {
        var current: NSSplitView? = start
        var safety = 0
        while let split = current, safety < 32 {
            safety += 1
            let parent = split.superview
            switch split.arrangedSubviews.count {
            case 0:
                split.removeFromSuperview()
                current = parent as? NSSplitView
            case 1:
                let next = parent as? NSSplitView
                guard collapseSingleChildSplit(split) else { return }
                current = next
            default:
                return
            }
            if split === root { return }
        }
    }

    @discardableResult
    private static func collapseRedundantSplits(in root: NSView) -> Bool {
        var changed = false
        var safety = 0
        while safety < 32 {
            safety += 1
            guard let split = firstRedundantSplit(below: root) else { break }
            if split.arrangedSubviews.isEmpty {
                split.removeFromSuperview()
                changed = true
            } else if collapseSingleChildSplit(split) {
                changed = true
            } else {
                break
            }
        }
        return changed
    }

    private static func firstRedundantSplit(below root: NSView) -> NSSplitView? {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView {
                for child in split.arrangedSubviews {
                    if let nested = find(child) { return nested }
                }
                if split.arrangedSubviews.count <= 1 { return split }
                return nil
            }
            for child in view.subviews {
                if let nested = find(child) { return nested }
            }
            return nil
        }
        for child in root.subviews {
            if let redundant = find(child) { return redundant }
        }
        return nil
    }

    private static func normalizeArrangedSubviewMasks(in view: NSView) {
        guard let split = view as? NSSplitView else { return }
        for child in split.arrangedSubviews {
            child.autoresizingMask = []
            normalizeArrangedSubviewMasks(in: child)
        }
    }

    private static func preferredRootAxis(for children: [NSView], in root: NSView) -> Bool {
        guard children.count > 1 else { return true }
        let frames = children.map { $0.convert($0.bounds, to: root) }
        let xSpread = (frames.map(\.midX).max() ?? 0) - (frames.map(\.midX).min() ?? 0)
        let ySpread = (frames.map(\.midY).max() ?? 0) - (frames.map(\.midY).min() ?? 0)
        return xSpread >= ySpread
    }

    private static func usableBounds(of root: NSView, fallback: NSRect) -> NSRect {
        root.bounds.width > 1 && root.bounds.height > 1 ? root.bounds : fallback
    }

    private static func equalize(_ split: NSSplitView) {
        let count = split.arrangedSubviews.count
        guard count > 1 else { return }
        let length = split.isVertical ? split.bounds.width : split.bounds.height
        guard length > 1 else { return }
        for index in 0..<(count - 1) {
            split.setPosition(
                length * CGFloat(index + 1) / CGFloat(count),
                ofDividerAt: index)
        }
    }

    /// Repair only impossible divider geometry. Valid non-zero splits retain
    /// their user ratios; a newly inserted split that has not reached its
    /// deferred centering pass gets an even initial distribution.
    private static func repairDegenerateSplits(in view: NSView) {
        guard let split = view as? NSSplitView else { return }
        split.layoutSubtreeIfNeeded()
        let count = split.arrangedSubviews.count
        let axisLength = split.isVertical ? split.bounds.width : split.bounds.height
        let crossLength = split.isVertical ? split.bounds.height : split.bounds.width
        if count >= 2, axisLength > CGFloat(count), crossLength > 1 {
            let hasDegenerateChild = split.arrangedSubviews.contains { child in
                let childAxis = split.isVertical ? child.frame.width : child.frame.height
                let childCross = split.isVertical ? child.frame.height : child.frame.width
                return childAxis < 1 || childCross < 1
            }
            if hasDegenerateChild {
                equalize(split)
                split.adjustSubviews()
            }
        }
        for child in split.arrangedSubviews {
            repairDegenerateSplits(in: child)
        }
    }

    @discardableResult
    static func replace(_ old: NSView, with new: NSView, in parent: NSView) -> Bool {
        let oldFrame = old.frame
        let oldAutoresizingMask = old.autoresizingMask
        if let split = parent as? NSSplitView {
            guard let index = split.arrangedSubviews.firstIndex(of: old) else {
                PaneLog.log("ERROR replace missing old=\(ObjectIdentifier(old)) "
                    + "parent=\(ObjectIdentifier(parent))")
                return false
            }
            old.removeFromSuperview()
            new.frame = oldFrame
            // NSSplitView owns arranged-subview geometry. Carrying a root
            // `.width/.height` mask into a nested slot lets AppKit resize the
            // child a second time while a drag is reparenting it.
            new.autoresizingMask = []
            split.insertArrangedSubview(new, at: index)
            PaneLog.log("replace split=\(ObjectIdentifier(split)) index=\(index) "
                + "old=\(ObjectIdentifier(old)) new=\(ObjectIdentifier(new))")
            return true
        }
        guard old.superview === parent else {
            PaneLog.log("ERROR replace parent mismatch old=\(ObjectIdentifier(old)) "
                + "expected=\(ObjectIdentifier(parent))")
            return false
        }
        new.frame = oldFrame
        new.autoresizingMask = oldAutoresizingMask
        parent.replaceSubview(old, with: new)
        PaneLog.log("replace view parent=\(ObjectIdentifier(parent)) "
            + "old=\(ObjectIdentifier(old)) new=\(ObjectIdentifier(new))")
        return true
    }

    /// Move an existing leaf without recreating its session. Edge drops nest
    /// it beside the target; center drops exchange leaf positions.
    static func move(
        source: NSView, target: NSView, zone: PaneDropZone
    ) -> (changed: Bool, insertedSplit: NSSplitView?) {
        guard source !== target, let sourceParent = source.superview,
              let targetParent = target.superview,
              topLayoutBranch(of: source) === topLayoutBranch(of: target) else {
            PaneLog.log("ERROR move invalid endpoints source=\(ObjectIdentifier(source)) "
                + "target=\(ObjectIdentifier(target)) zone=\(zone)")
            return (false, nil)
        }
        PaneLog.log("layout move zone=\(zone) source=\(ObjectIdentifier(source)) "
            + "target=\(ObjectIdentifier(target))")
        if zone == .center {
            let sourcePlaceholder = NSView(frame: source.frame)
            let targetPlaceholder = NSView(frame: target.frame)
            guard replace(source, with: sourcePlaceholder, in: sourceParent),
                  replace(target, with: targetPlaceholder, in: targetParent),
                  let sourceSlot = sourcePlaceholder.superview,
                  let targetSlot = targetPlaceholder.superview,
                  replace(sourcePlaceholder, with: target, in: sourceSlot),
                  replace(targetPlaceholder, with: source, in: targetSlot)
            else {
                PaneLog.log("ERROR center swap failed source=\(ObjectIdentifier(source)) "
                    + "target=\(ObjectIdentifier(target))")
                return (false, nil)
            }
            normalizeArrangedSubviewMasks(around: source)
            return (true, nil)
        }

        guard let sourceSplit = sourceParent as? NSSplitView else {
            PaneLog.log("ERROR edge move source parent is not split "
                + "source=\(ObjectIdentifier(source)) parent=\(ObjectIdentifier(sourceParent))")
            return (false, nil)
        }
        // Reorient a two-pane sibling split in place. Building a nested split,
        // removing the source, then collapsing the old root briefly detaches
        // the only layout node from TerminalChromeView; AppKit can resolve
        // that transient tree to a zero-width, double-height stack.
        if targetParent === sourceSplit, sourceSplit.arrangedSubviews.count == 2 {
            source.removeFromSuperview()
            target.removeFromSuperview()
            sourceSplit.isVertical = zone == .left || zone == .right
            source.autoresizingMask = []
            target.autoresizingMask = []
            if zone == .left || zone == .top {
                sourceSplit.addArrangedSubview(source)
                sourceSplit.addArrangedSubview(target)
            } else {
                sourceSplit.addArrangedSubview(target)
                sourceSplit.addArrangedSubview(source)
            }
            normalizeArrangedSubviewMasks(around: source)
            PaneLog.log("reorient two-pane split=\(ObjectIdentifier(sourceSplit)) "
                + "vertical=\(sourceSplit.isVertical) zone=\(zone)")
            return (true, sourceSplit)
        }
        let split = PaneSplitView(frame: target.frame)
        split.isVertical = zone == .left || zone == .right
        split.dividerStyle = .thin
        split.autoresizingMask = []
        // Replace the target before detaching the source. This is the only
        // fallible topology mutation; once it succeeds, the remaining moves
        // cannot strand a detached pane if the target slot was invalid.
        guard replace(target, with: split, in: targetParent) else { return (false, nil) }
        target.autoresizingMask = []
        split.addArrangedSubview(target)
        source.removeFromSuperview()
        collapseSingleChildSplit(sourceSplit)
        source.autoresizingMask = []
        // Horizontal NSSplitView order is visual top-to-bottom, so a bottom
        // drop appends after the target while a top drop inserts before it.
        if zone == .left || zone == .top {
            split.insertArrangedSubview(source, at: 0)
        } else {
            split.addArrangedSubview(source)
        }
        normalizeArrangedSubviewMasks(around: source)
        return (true, split)
    }

    private static func topLayoutBranch(of view: NSView) -> NSView {
        var branch = view
        while let parent = branch.superview as? NSSplitView { branch = parent }
        return branch
    }

    private static func normalizeArrangedSubviewMasks(around view: NSView) {
        var root = view
        while let parent = root.superview as? NSSplitView { root = parent }
        guard let split = root as? NSSplitView else { return }
        func normalize(_ current: NSSplitView) {
            for child in current.arrangedSubviews {
                child.autoresizingMask = []
                if let nested = child as? NSSplitView { normalize(nested) }
            }
        }
        normalize(split)
    }

    /// Dissolve a one-child split without exposing an empty plain container.
    /// `TerminalChromeView.body` lays out all of its direct children together;
    /// briefly removing its only child can make AppKit retain a zero-sized
    /// layout result through the next display pass. A placeholder preserves
    /// the root slot while the survivor changes parents.
    @discardableResult
    static func collapseSingleChildSplit(_ split: NSSplitView) -> Bool {
        guard split.arrangedSubviews.count == 1,
              let parent = split.superview else { return false }
        let survivor = split.arrangedSubviews[0]
        PaneLog.log("collapse split=\(ObjectIdentifier(split)) "
            + "survivor=\(ObjectIdentifier(survivor)) parent=\(ObjectIdentifier(parent))")

        if parent is NSSplitView {
            survivor.removeFromSuperview()
            if !replace(split, with: survivor, in: parent) {
                split.addArrangedSubview(survivor)
                PaneLog.log("ERROR collapse replace failed split=\(ObjectIdentifier(split))")
                return false
            }
            return true
        }

        // replaceSubview swaps the root atomically; no empty host or temporary
        // second layout branch is exposed to TerminalChromeView.
        let fill = usableBounds(of: parent, fallback: split.frame)
        survivor.removeFromSuperview()
        if !replace(split, with: survivor, in: parent) {
            split.addArrangedSubview(survivor)
            PaneLog.log("ERROR collapse survivor failed split=\(ObjectIdentifier(split))")
            return false
        }
        prepareFrameManaged(survivor, filling: fill)
        return true
    }

    /// Make `view` the frame-managed child of a plain pane host.
    /// Internal constraints belong to the pane and must never be stripped.
    static func prepareFrameManaged(_ view: NSView, filling bounds: NSRect) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        if bounds.width > 1, bounds.height > 1 {
            view.frame = bounds
        }
    }

    static func captureDividerPositions(in root: NSView) -> DividerPositions {
        var result: DividerPositions = []
        func collect(_ view: NSView) {
            if let split = view as? NSSplitView {
                let positions = split.arrangedSubviews.dropLast().map {
                    split.isVertical ? $0.frame.maxX : $0.frame.maxY
                }
                result.append((split, positions))
                split.arrangedSubviews.forEach(collect)
            } else {
                view.subviews.forEach(collect)
            }
        }
        collect(root)
        return result
    }

    static func restoreDividerPositions(_ snapshots: DividerPositions) {
        for snapshot in snapshots
        where snapshot.split.superview != nil
            && snapshot.split.arrangedSubviews.count == snapshot.positions.count + 1 {
            for (index, position) in snapshot.positions.enumerated() {
                snapshot.split.setPosition(position, ofDividerAt: index)
            }
        }
    }

    /// Zoom snapshots are ratios rather than pixels so restoring after a
    /// window resize preserves the layout the user had before maximizing.
    static func captureDividerRatios(in root: NSView) -> DividerRatios {
        ratios(for: captureDividerPositions(in: root))
    }

    static func ratios(for snapshots: DividerPositions) -> DividerRatios {
        snapshots.map { snapshot in
            let length = snapshot.split.isVertical
                ? snapshot.split.bounds.width : snapshot.split.bounds.height
            let denominator = max(length, 1)
            return (snapshot.split, snapshot.positions.map { $0 / denominator })
        }
    }

    static func positions(
        for snapshot: (split: NSSplitView, ratios: [CGFloat])
    ) -> [CGFloat] {
        let length = snapshot.split.isVertical
            ? snapshot.split.bounds.width : snapshot.split.bounds.height
        return snapshot.ratios.map { min(max($0, 0), 1) * length }
    }

    static func restoreDividerRatios(_ snapshots: DividerRatios) {
        for snapshot in snapshots where snapshot.split.superview != nil {
            let values = positions(for: snapshot)
            guard snapshot.split.arrangedSubviews.count == values.count + 1 else { continue }
            for (index, position) in values.enumerated() {
                snapshot.split.setPosition(position, ofDividerAt: index)
            }
        }
    }

    static func maximizedDividerPositions(
        length: CGFloat, childCount: Int, selectedIndex: Int,
        collapsedExtent: CGFloat, dividerThickness: CGFloat
    ) -> [CGFloat] {
        guard childCount > 1, (0..<childCount).contains(selectedIndex) else { return [] }
        let dividerTotal = dividerThickness * CGFloat(childCount - 1)
        let available = max(length - dividerTotal, 0)
        let sideExtent = min(
            collapsedExtent,
            available / CGFloat(childCount))
        let selectedExtent = max(available - sideExtent * CGFloat(childCount - 1), 0)
        let extents = (0..<childCount).map {
            $0 == selectedIndex ? selectedExtent : sideExtent
        }
        var positions: [CGFloat] = []
        var cursor: CGFloat = 0
        for index in 0..<(childCount - 1) {
            cursor += extents[index]
            positions.append(cursor)
            cursor += dividerThickness
        }
        return positions
    }
}

private final class PaneSplitButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

/// The small, persistent collaboration port in every pane header. A click
/// opens the channel surface; dragging the port to another pane asks the room
/// kernel to link the two endpoints. The callback coordinates are in global
/// screen space so a drag can cross native windows without changing meaning.
final class ChannelConnectorView: NSView {
    var onActivate: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, Bool) -> Void)?

    private(set) var channelName: String?
    private(set) var memberCount = 0
    private(set) var channelColor = NSColor.secondaryLabelColor
    private var isDropTarget = false
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
        toolTip = "Drag to connect this pane to a Channel"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func setChannel(name: String?, color: NSColor?, memberCount: Int) {
        channelName = name
        channelColor = color ?? NSColor.secondaryLabelColor
        self.memberCount = max(memberCount, 0)
        toolTip = name.map {
            "\($0), \(self.memberCount) connected panes. Drag to extend or click to open."
        } ?? "Drag to connect this pane to a Channel"
        updateAccessibility()
        needsDisplay = true
    }

    func setDropTarget(_ active: Bool) {
        guard isDropTarget != active else { return }
        isDropTarget = active
        needsDisplay = true
    }

    var isDropTargetForTesting: Bool { isDropTarget }
    var accessibilityLabelForTesting: String { accessibilityLabel() ?? "" }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    private func updateAccessibility() {
        if let channelName {
            let spokenName = channelName.lowercased().hasPrefix("channel")
                ? channelName
                : "Channel \(channelName)"
            setAccessibilityLabel(
                "\(spokenName), \(memberCount) connected panes")
        } else {
            setAccessibilityLabel("Connect pane to a Channel")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let connected = channelName != nil
        let outer = bounds.insetBy(dx: 5, dy: 5)
        let color = connected ? channelColor : NSColor.secondaryLabelColor

        if isDropTarget || isDragging {
            color.withAlphaComponent(isDropTarget ? 0.24 : 0.14).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }

        let ring = NSBezierPath(ovalIn: outer)
        ring.lineWidth = isDropTarget ? 2.5 : 1.5
        color.withAlphaComponent(connected ? 0.95 : 0.55).setStroke()
        ring.stroke()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dot = NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
        color.withAlphaComponent(connected ? 0.95 : 0.44).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else { return }
        let startWindowPoint = event.locationInWindow
        let startScreenPoint = window.convertPoint(toScreen: startWindowPoint)
        var dragging = false

        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown])
        {
            let screenPoint = window.convertPoint(toScreen: next.locationInWindow)
            switch next.type {
            case .leftMouseDragged:
                if !dragging,
                   hypot(
                    next.locationInWindow.x - startWindowPoint.x,
                    next.locationInWindow.y - startWindowPoint.y) > 4
                {
                    dragging = true
                    isDragging = true
                    needsDisplay = true
                    onDragBegan?(startScreenPoint)
                }
                if dragging { onDragMoved?(screenPoint) }
            case .leftMouseUp:
                if dragging {
                    isDragging = false
                    needsDisplay = true
                    onDragEnded?(screenPoint, false)
                } else {
                    onActivate?()
                }
                return
            case .keyDown where next.keyCode == 53:
                if dragging {
                    isDragging = false
                    needsDisplay = true
                    onDragEnded?(screenPoint, true)
                }
                return
            default:
                break
            }
        }

        if dragging {
            isDragging = false
            needsDisplay = true
            onDragEnded?(startScreenPoint, true)
        }
    }
}

/// A short-lived, click-through overlay used only while a connector is being
/// dragged. One panel per display avoids a giant cross-display backing store.
/// Points remain in AppKit screen coordinates and are projected by each view.
final class ChannelWireOverlay {
    private final class WireView: NSView {
        let screenFrame: NSRect
        var start = NSPoint.zero
        var end = NSPoint.zero
        var color = NSColor.controlAccentColor

        init(screenFrame: NSRect) {
            self.screenFrame = screenFrame
            super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let localStart = NSPoint(
                x: start.x - screenFrame.minX, y: start.y - screenFrame.minY)
            let localEnd = NSPoint(
                x: end.x - screenFrame.minX, y: end.y - screenFrame.minY)
            let delta = max(abs(localEnd.x - localStart.x) * 0.42, 36)
            let path = NSBezierPath()
            path.move(to: localStart)
            path.curve(
                to: localEnd,
                controlPoint1: NSPoint(
                    x: localStart.x + copysign(delta, localEnd.x - localStart.x),
                    y: localStart.y),
                controlPoint2: NSPoint(
                    x: localEnd.x - copysign(delta, localEnd.x - localStart.x),
                    y: localEnd.y))
            path.lineWidth = 2
            path.lineCapStyle = .round
            color.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    private struct Entry {
        let panel: NSPanel
        let wire: WireView
    }

    private var entries: [Entry] = []

    init(start: NSPoint, color: NSColor) {
        for screen in NSScreen.screens {
            let wire = WireView(screenFrame: screen.frame)
            wire.start = start
            wire.end = start
            wire.color = color
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen)
            panel.contentView = wire
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
            entries.append(Entry(panel: panel, wire: wire))
        }
    }

    func update(end: NSPoint, color: NSColor? = nil) {
        for entry in entries {
            entry.wire.end = end
            if let color { entry.wire.color = color }
            entry.wire.needsDisplay = true
        }
    }

    func close() {
        for entry in entries { entry.panel.close() }
        entries.removeAll()
    }

    deinit { close() }
}

final class PaneHeaderView: NSView {
    static let height: CGFloat = 28

    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onChooseSplitRight: (() -> Void)?
    var onChooseSplitDown: (() -> Void)?
    var onToggleTodos: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    var onFocus: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, Bool) -> Void)?
    var onChannelActivate: (() -> Void)? {
        didSet { channelConnector.onActivate = onChannelActivate }
    }
    var onChannelDragBegan: ((NSPoint) -> Void)? {
        didSet { channelConnector.onDragBegan = onChannelDragBegan }
    }
    var onChannelDragMoved: ((NSPoint) -> Void)? {
        didSet { channelConnector.onDragMoved = onChannelDragMoved }
    }
    var onChannelDragEnded: ((NSPoint, Bool) -> Void)? {
        didSet { channelConnector.onDragEnded = onChannelDragEnded }
    }
    /// When set, hovering the pane icon turns it into a close button.
    var onClose: (() -> Void)? {
        didSet { iconView.toolTip = onClose == nil ? nil : "Close Pane" }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let splitRightButton = PaneSplitButton()
    private let splitDownButton = PaneSplitButton()
    private let todoButton = PaneSplitButton()
    private let channelBadge = NSTextField(labelWithString: "")
    private let channelConnector = ChannelConnectorView()
    private var todoTotal = 0
    private let bottomHairline = NSView()
    private var channelHairlineColor: NSColor?
    private var closeHoverActive = false
    private var iconTrackingArea: NSTrackingArea?
    private weak var renameEditor: TabRenameTextView?

    var iconSymbol: String = "terminal" {
        didSet { updateIcon() }
    }

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel("Terminal pane: \(newValue)")
            needsLayout = true
        }
    }

    var splitRightAccessibilityLabelForTesting: String {
        splitRightButton.accessibilityLabel() ?? ""
    }
    var splitDownAccessibilityLabelForTesting: String {
        splitDownButton.accessibilityLabel() ?? ""
    }
    var iconFrameForTesting: NSRect { iconView.frame }
    var titleFrameForTesting: NSRect { titleLabel.frame }
    var splitRightFrameForTesting: NSRect { splitRightButton.frame }
    var splitDownFrameForTesting: NSRect { splitDownButton.frame }
    var isRenamingForTesting: Bool { renameEditor != nil }
    var todoButtonIsVisibleForTesting: Bool { !todoButton.isHidden }
    var todoTooltipForTesting: String { todoButton.toolTip ?? "" }
    var channelConnectorFrameForTesting: NSRect { channelConnector.frame }
    var channelConnectorAccessibilityLabelForTesting: String {
        channelConnector.accessibilityLabelForTesting
    }
    var channelBadgeTextForTesting: String { channelBadge.stringValue }
    var channelBadgeIsHiddenForTesting: Bool { channelBadge.isHidden }
    var channelBadgeFrameForTesting: NSRect { channelBadge.frame }

    /// Anchor for the todo popover.
    var todoAnchorView: NSView { todoButton }
    var channelAnchorView: NSView { channelConnector }

    var channelConnectorScreenFrame: NSRect? {
        guard let window = channelConnector.window else { return nil }
        let frameInWindow = channelConnector.convert(channelConnector.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func setChannel(name: String?, color: NSColor?, memberCount: Int) {
        channelHairlineColor = name == nil ? nil : color
        channelConnector.setChannel(name: name, color: color, memberCount: memberCount)
        channelBadge.stringValue = name.map { "\($0) · \(memberCount)" } ?? ""
        channelBadge.isHidden = name == nil
        channelBadge.textColor = (color ?? NSColor.controlAccentColor)
            .blended(withFraction: 0.22, of: .white)
            ?? color
            ?? NSColor.labelColor
        channelBadge.layer?.backgroundColor = (color ?? NSColor.controlAccentColor)
            .withAlphaComponent(0.16).cgColor
        channelBadge.setAccessibilityLabel(
            name.map { "\($0), \(memberCount) connected panes" })
        bottomHairline.layer?.backgroundColor = channelHairlineColor?
            .withAlphaComponent(0.5).cgColor ?? NSColor.clear.cgColor
        needsLayout = true
    }

    func setChannelDropTarget(_ active: Bool) {
        channelConnector.setDropTarget(active)
    }

    /// Show/hide the checklist icon and reflect progress in its tooltip and
    /// tint (accent while work remains, green when everything is done).
    func setTodoProgress(total: Int, done: Int) {
        todoTotal = total
        todoButton.isHidden = total == 0
        guard total > 0 else { return }
        todoButton.toolTip = "Agent todos: \(done)/\(total) done"
        todoButton.setAccessibilityLabel("Agent todo list, \(done) of \(total) done")
        todoButton.contentTintColor = done == total
            ? NSColor.systemGreen.withAlphaComponent(0.8)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.85)
        needsLayout = true
    }

    @objc private func todoPressed(_ sender: Any?) {
        onToggleTodos?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        updateIcon()
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        configure(
            splitRightButton, symbol: "rectangle.split.2x1",
            label: "Split pane right", action: #selector(splitRightPressed))
        splitRightButton.onRightClick = { [weak self] in self?.onChooseSplitRight?() }
        configure(
            splitDownButton, symbol: "rectangle.split.1x2",
            label: "Split pane down", action: #selector(splitDownPressed))
        splitDownButton.onRightClick = { [weak self] in self?.onChooseSplitDown?() }
        configure(
            todoButton, symbol: "checklist",
            label: "Agent todo list", action: #selector(todoPressed))
        todoButton.isHidden = true

        channelBadge.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        channelBadge.alignment = .center
        channelBadge.lineBreakMode = .byTruncatingTail
        channelBadge.wantsLayer = true
        channelBadge.layer?.cornerRadius = 8
        channelBadge.layer?.masksToBounds = true
        channelBadge.isHidden = true
        addSubview(channelBadge)
        addSubview(channelConnector)

        bottomHairline.wantsLayer = true
        bottomHairline.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bottomHairline)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal pane")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateIcon() {
        guard !closeHoverActive else { return }
        iconView.image = NSImage(
            systemSymbolName: iconSymbol, accessibilityDescription: titleLabel.stringValue)
    }

    /// Slightly padded hit region so the close affordance is easy to target.
    private var iconHoverRect: NSRect { iconView.frame.insetBy(dx: -3, dy: -3) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let iconTrackingArea { removeTrackingArea(iconTrackingArea) }
        let area = NSTrackingArea(
            rect: iconHoverRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        iconTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard onClose != nil, !closeHoverActive else { return }
        closeHoverActive = true
        iconView.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pane")
        iconView.contentTintColor = NSColor.systemRed.withAlphaComponent(0.85)
    }

    override func mouseExited(with event: NSEvent) {
        guard closeHoverActive else { return }
        closeHoverActive = false
        iconView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        updateIcon()
    }

    var closeHoverActiveForTesting: Bool { closeHoverActive }
    func simulateIconHoverForTesting(_ inside: Bool) {
        let event = NSEvent.enterExitEvent(
            with: inside ? .mouseEntered : .mouseExited,
            location: NSPoint(x: iconHoverRect.midX, y: iconHoverRect.midY),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)
        guard let event else { return }
        inside ? mouseEntered(with: event) : mouseExited(with: event)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.62)
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 26
        splitDownButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 8, y: 1, width: buttonSize, height: buttonSize)
        splitRightButton.frame = NSRect(
            x: splitDownButton.frame.minX - buttonSize, y: 1,
            width: buttonSize, height: buttonSize)
        todoButton.frame = NSRect(
            x: splitRightButton.frame.minX - (todoButton.isHidden ? 0 : buttonSize), y: 1,
            width: buttonSize, height: buttonSize)
        let connectorSize: CGFloat = 28
        channelConnector.frame = NSRect(
            x: todoButton.frame.minX - connectorSize, y: 0,
            width: connectorSize, height: connectorSize)
        let badgeWidth: CGFloat
        if channelBadge.isHidden {
            badgeWidth = 0
            channelBadge.frame = .zero
        } else {
            let badgeTextWidth = ceil(
                channelBadge.stringValue.size(withAttributes: [
                .font: channelBadge.font as Any,
            ]).width)
            let titleTextWidth = ceil(
                titleLabel.stringValue.size(withAttributes: [
                    .font: titleLabel.font as Any,
                ]).width)
            let minimumTitleWidth = min(
                max(titleTextWidth + 6, 42),
                96)
            let idealBadgeWidth = min(
                max(badgeTextWidth + 16, 62),
                132)
            let maximumBadgeWidth = max(
                channelConnector.frame.minX
                    - 43
                    - minimumTitleWidth,
                0)
            if maximumBadgeWidth >= 48 {
                badgeWidth = min(
                    idealBadgeWidth,
                    maximumBadgeWidth)
                channelBadge.frame = NSRect(
                    x: channelConnector.frame.minX - badgeWidth - 4,
                    y: 5, width: badgeWidth, height: 18)
            } else {
                // At extremely small widths the connected ring remains
                // visible and accessible; do not erase the unique pane name
                // merely to fit a second text label.
                badgeWidth = 0
                channelBadge.frame = .zero
            }
        }
        iconView.frame = NSRect(x: 10, y: 6, width: 16, height: 16)
        let titleLimit = channelBadge.isHidden
            ? channelConnector.frame.minX
            : channelBadge.frame.minX
        titleLabel.frame = NSRect(
            x: 32, y: 1,
            width: max(titleLimit - 39, 0), height: 20)
        if let renameEditor {
            renameEditor.frame = renameFrame
        }
        bottomHairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    private var renameFrame: NSRect {
        let name = renameEditor?.string ?? title
        let textWidth = ceil(name.size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
        ]).width)
        let width = min(titleLabel.frame.width, max(96, textWidth + 28))
        return NSRect(
            x: titleLabel.frame.minX - 4, y: 3,
            width: width, height: 22)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if closeHoverActive, let onClose,
           iconHoverRect.contains(convert(event.locationInWindow, from: nil)) {
            onClose()
            return
        }
        onFocus?()
        if event.clickCount >= 2 {
            let point = convert(event.locationInWindow, from: nil)
            if titleLabel.frame.insetBy(dx: -5, dy: -4).contains(point) {
                beginRename()
                return
            }
            onToggleZoom?()
            return
        }
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch next.type {
            case .leftMouseDragged:
                guard window.isKeyWindow else {
                    if dragging { onDragEnded?(next.locationInWindow, true) }
                    return
                }
                let point = next.locationInWindow
                if !dragging, hypot(point.x - start.x, point.y - start.y) > 4 {
                    dragging = true
                    onDragBegan?(point)
                }
                if dragging { onDragMoved?(point) }
            case .leftMouseUp:
                if dragging { onDragEnded?(next.locationInWindow, !window.isKeyWindow) }
                return
            case .keyDown where next.keyCode == 53: // Escape
                if dragging { onDragEnded?(next.locationInWindow, true) }
                return
            default:
                break
            }
        }
        if dragging { onDragEnded?(start, true) }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(panelContextMenu(), with: event, for: self)
    }

    private func panelContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Panel")
        let rename = menu.addItem(
            withTitle: "Rename Panel…", action: #selector(renamePanel(_:)),
            keyEquivalent: "")
        rename.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "New Chat",
            action: #selector(AppDelegate.newChatPane(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Browser",
            action: #selector(AppDelegate.openBrowserPane(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Files",
            action: #selector(AppDelegate.openFilesPane(_:)), keyEquivalent: "")
        return menu
    }

    var contextMenuTitlesForTesting: [String] {
        panelContextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @objc private func renamePanel(_ sender: Any?) {
        beginRename()
    }

    func beginRename() {
        guard renameEditor == nil else { return }
        onFocus?()
        layoutSubtreeIfNeeded()
        let editor = TabRenameTextView(frame: renameFrame)
        editor.string = title
        editor.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 5, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byClipping
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 4
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = CodePalette.selectionAccent.cgColor
        editor.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.96).cgColor
        editor.onCommit = { [weak self] in self?.finishRename(committing: true) }
        editor.onCancel = { [weak self] in self?.finishRename(committing: false) }
        titleLabel.isHidden = true
        addSubview(editor, positioned: .above, relativeTo: nil)
        renameEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(
            NSRange(location: 0, length: (editor.string as NSString).length))
    }

    private func finishRename(committing: Bool) {
        guard let editor = renameEditor else { return }
        let value = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        renameEditor = nil
        editor.onCommit = nil
        editor.onCancel = nil
        editor.removeFromSuperview()
        titleLabel.isHidden = false
        if committing, !value.isEmpty {
            var bounded = ""
            var bytes = 0
            for character in value {
                let part = String(character)
                guard bytes + part.utf8.count <= 80 else { break }
                bounded.append(character)
                bytes += part.utf8.count
            }
            title = bounded
            onRenameCommit?(bounded)
        }
        onFocus?()
    }

    @objc private func splitRightPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onChooseSplitRight?()
        } else {
            onSplitRight?()
        }
    }

    @objc private func splitDownPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onChooseSplitDown?()
        } else {
            onSplitDown?()
        }
    }

}

final class PaneDropPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = PaneMetrics.cornerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PaneOutlineView: NSView {
    var accentColor = CodePalette.paneFocusAccent {
        didSet { updateAppearance(animated: window != nil) }
    }
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance(animated: window != nil)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = PaneMetrics.cornerRadius
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateAppearance(animated: Bool) {
        let oldBackground = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        let oldBorder = layer?.presentation()?.borderColor ?? layer?.borderColor
        let background = accentColor.withAlphaComponent(
            isSelected ? 0.09 : 0.045).cgColor
        let border = (isSelected
            ? accentColor.withAlphaComponent(0.68)
            : accentColor.withAlphaComponent(0.30)).cgColor
        layer?.backgroundColor = background
        layer?.borderColor = border
        layer?.borderWidth = isSelected ? 1.5 : 1
        guard animated else { return }
        for (keyPath, from, to) in [
            ("backgroundColor", oldBackground, background),
            ("borderColor", oldBorder, border),
        ] {
            let transition = CABasicAnimation(keyPath: keyPath)
            transition.fromValue = from
            transition.toValue = to
            transition.duration = 0.18
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: "pane-\(keyPath)")
        }
    }

    var backgroundAlphaForTesting: CGFloat {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }
    var accentColorForTesting: NSColor { accentColor }
}

final class PaneDragBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: 7, y: 6, width: 12, height: 12)
        addSubview(icon)

        label.stringValue = title
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 24, y: 4, width: 88, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
