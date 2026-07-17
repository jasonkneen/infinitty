import AppKit

extension NSEvent.ModifierFlags {
    /// Just the four modifier keys that participate in shortcut matching,
    /// with device-dependent and lock bits stripped.
    var shortcutModifiers: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
    }
}

enum PaneFocusDirection {
    case left
    case right
    case up
    case down
}

struct PaneNavigation {
    /// Pane-navigation arrows remain application shortcuts while a terminal
    /// owns focus, even when there is no pane in that direction. Other
    /// responders should receive the key so normal text selection still works.
    static func shouldForwardUnmatchedArrow(terminalHasFocus: Bool) -> Bool {
        !terminalHasFocus
    }

    static func shortcutNumber(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        guard modifiers.shortcutModifiers == [.shift, .option] else { return nil }
        return [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9,
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5,
            88: 6, 89: 7, 91: 8, 92: 9,
        ][keyCode]
    }

    static func index(for shortcutNumber: Int, paneCount: Int) -> Int? {
        guard paneCount > 0, (1...9).contains(shortcutNumber) else { return nil }
        let index = shortcutNumber - 1
        return index < paneCount ? index : nil
    }

    /// Shift-Option-digit is claimed only when a
    /// terminal pane owns keyboard focus and there is actually a split to
    /// navigate; otherwise the key event must continue to the terminal/UI.
    static func shortcutTargetIndex(
        for shortcutNumber: Int,
        paneCount: Int,
        terminalHasFocus: Bool
    ) -> Int? {
        guard terminalHasFocus, paneCount > 1 else { return nil }
        return index(for: shortcutNumber, paneCount: paneCount)
    }

    /// Finds the visually nearest pane in `direction`. A candidate that
    /// overlaps the current pane on the perpendicular axis is preferred;
    /// diagonal candidates remain reachable when a nested split has no direct
    /// neighbor.
    static func targetIndex(
        from currentIndex: Int,
        frames: [NSRect],
        direction: PaneFocusDirection
    ) -> Int? {
        guard frames.indices.contains(currentIndex) else { return nil }
        let current = frames[currentIndex]
        let epsilon: CGFloat = 0.5

        struct Candidate {
            let index: Int
            let score: CGFloat
            let perpendicularDistance: CGFloat
        }

        func intervalGap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
            if a.upperBound < b.lowerBound { return b.lowerBound - a.upperBound }
            if b.upperBound < a.lowerBound { return a.lowerBound - b.upperBound }
            return 0
        }

        let candidates: [Candidate] = frames.indices.compactMap { index in
            guard index != currentIndex else { return nil }
            let frame = frames[index]
            let primaryDistance: CGFloat
            let perpendicularDistance: CGFloat
            let perpendicularGap: CGFloat

            switch direction {
            case .left:
                guard frame.maxX <= current.minX + epsilon else { return nil }
                primaryDistance = max(current.minX - frame.maxX, 0)
                perpendicularDistance = abs(current.midY - frame.midY)
                perpendicularGap = intervalGap(
                    current.minY...current.maxY, frame.minY...frame.maxY)
            case .right:
                guard frame.minX >= current.maxX - epsilon else { return nil }
                primaryDistance = max(frame.minX - current.maxX, 0)
                perpendicularDistance = abs(current.midY - frame.midY)
                perpendicularGap = intervalGap(
                    current.minY...current.maxY, frame.minY...frame.maxY)
            case .up:
                guard frame.minY >= current.maxY - epsilon else { return nil }
                primaryDistance = max(frame.minY - current.maxY, 0)
                perpendicularDistance = abs(current.midX - frame.midX)
                perpendicularGap = intervalGap(
                    current.minX...current.maxX, frame.minX...frame.maxX)
            case .down:
                guard frame.maxY <= current.minY + epsilon else { return nil }
                primaryDistance = max(current.minY - frame.maxY, 0)
                perpendicularDistance = abs(current.midX - frame.midX)
                perpendicularGap = intervalGap(
                    current.minX...current.maxX, frame.minX...frame.maxX)
            }

            return Candidate(
                index: index,
                score: primaryDistance + perpendicularGap * 4,
                perpendicularDistance: perpendicularDistance)
        }

        return candidates.min {
            if abs($0.score - $1.score) > epsilon { return $0.score < $1.score }
            if abs($0.perpendicularDistance - $1.perpendicularDistance) > epsilon {
                return $0.perpendicularDistance < $1.perpendicularDistance
            }
            return $0.index < $1.index
        }?.index
    }
}

struct TabNavigation {
    /// Physical left/right arrow shortcuts are decoded here rather than left
    /// solely to AppKit menu-equivalent matching. This keeps tab cycling
    /// reliable while a terminal view owns first responder.
    static func cycleOffset(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        guard modifiers.shortcutModifiers == [.command, .shift] else { return nil }
        switch keyCode {
        case 123: return -1 // left arrow
        case 124: return 1  // right arrow
        default: return nil
        }
    }

    static func cycledIndex(from index: Int, offset: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, (0..<tabCount).contains(index) else { return nil }
        let normalizedOffset = offset % tabCount
        return (index + normalizedOffset + tabCount) % tabCount
    }

    /// Command-1...8 select that position; Command-9 follows the common macOS
    /// convention of selecting the last tab.
    static func index(for shortcutNumber: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, (1...9).contains(shortcutNumber) else { return nil }
        let index = shortcutNumber == 9 ? tabCount - 1 : shortcutNumber - 1
        return index < tabCount ? index : nil
    }

    static func shortcutNumber(forTabIndex index: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, index >= 0, index < tabCount else { return nil }
        if index < 8 { return index + 1 }
        return index == tabCount - 1 ? 9 : nil
    }
}
