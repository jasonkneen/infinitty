import AppKit
import XCTest
@testable import InfinittyKit

final class CodeViewTests: XCTestCase {

    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "/infinitty-codeview-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tempDir + "/Sources", withIntermediateDirectories: true)
        try "let x = 1\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func mountedController() -> (CodeViewController, NSWindow) {
        let controller = CodeViewController(config: AppConfig())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.layoutIfNeeded()
        return (controller, window)
    }

    func testTreePopulatesForDirectory() {
        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        XCTAssertEqual(controller.topLevelRowCountForTesting, 2)
    }

    func testRowsRenderWithHeightAndLabels() {
        let (controller, window) = mountedController()
        controller.reRootForTesting(tempDir)
        window.contentView?.layoutSubtreeIfNeeded()
        // Rows must occupy real pixels and cells must carry the file names.
        XCTAssertGreaterThan(controller.rectOfFirstRowForTesting().height, 0)
        // Directories sort first: "Sources", then "Package.swift".
        XCTAssertEqual(controller.cellTextForTesting(row: 0), "Sources")
        XCTAssertEqual(controller.cellTextForTesting(row: 1), "Package.swift")
    }

    func testPreviewLoadsSelectedFile() {
        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.loadPreviewForTesting(
            URL(fileURLWithPath: tempDir + "/Package.swift"))
        XCTAssertTrue(controller.previewTextForTesting.contains("let x = 1"))
    }

    /// Replicates the full real-app flow: terminal in a window, wrap in the
    /// outer split, async divider positioning, then a layout pass — and dumps
    /// the resulting frames so a collapsed tree shows up in the failure log.
    func testFullToggleFlowKeepsTreeVisible() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let terminal = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.autoresizingMask = [.width, .height]
        window.contentView = terminal

        let controller = CodeViewController(config: AppConfig())
        let split = NSSplitView(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        window.contentView = split
        split.addArrangedSubview(terminal)
        split.addArrangedSubview(controller.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)

        controller.reRootForTesting(tempDir)

        let exp = expectation(description: "divider positioned")
        DispatchQueue.main.async {
            split.setPosition(split.bounds.width - 280, ofDividerAt: 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        // Run a couple more layout rounds like a live window would.
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let summary = controller.layoutSummaryForTesting()
        XCTAssertGreaterThan(controller.view.frame.width, 100, summary)
        XCTAssertEqual(controller.topLevelRowCountForTesting, 2, summary)
        let row0 = controller.rectOfFirstRowForTesting()
        XCTAssertGreaterThan(row0.height, 0, summary)
    }

    /// The Files|Changes bar must stay a compact capsule in the live window —
    /// a regression guard for the giant-ellipse layout bug where the bar's
    /// intrinsic height was not honored and it ballooned to fill the sidebar.
    func testPageControlKeepsCompactHeightInTallSidebar() {
        let controller = CodeViewController(config: AppConfig())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 940),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let frame = controller.pageControlFrameForTesting
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertLessThanOrEqual(frame.height, 40, "frame=\(frame)")
    }

    func testSidebarUsesDefaultTypographyAndLargerFileIcons() {
        let (controller, window) = mountedController()
        controller.reRootForTesting(tempDir)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.pageControlLabelsForTesting, ["FILES", "CHANGES", "CHAT"])
        XCTAssertEqual(controller.pageControlFontSizeForTesting, 10)
        XCTAssertEqual(
            controller.pageControlFontWeightForTesting,
            NSFont.Weight.medium.rawValue)
        XCTAssertEqual(controller.searchFontSizeForTesting, NSFont.systemFontSize)
        XCTAssertEqual(controller.cellFontSizeForTesting(row: 0), NSFont.systemFontSize)
        XCTAssertEqual(controller.cellIconSizeForTesting(row: 0), 16)
    }

    func testSidebarChromeUsesSquaredSearchAndNeutralTabStates() {
        let controller = CodeViewController(config: AppConfig())
        _ = controller.view

        XCTAssertEqual(controller.searchCornerRadiusForTesting, 6)
        XCTAssertTrue(controller.pageControlHasOutlineForTesting)
        XCTAssertTrue(controller.tabAndRowSelectionMatchForTesting)
        XCTAssertTrue(controller.diffModeSelectionIsNeutralForTesting)
    }

    /// In the live window the sidebar can get a layout pass at a stub size
    /// before reaching its real height (contentView swap on a visible
    /// window). The tree must survive that growth, not stay squashed.
    func testTreeKeepsHeightWhenSidebarGrowsAfterSmallLayout() {
        let controller = CodeViewController(config: AppConfig())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        window.contentView = container
        container.addSubview(controller.view)
        controller.reRootForTesting(tempDir)

        controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(controller.treeHeightForTesting(), 100,
                             controller.layoutSummaryForTesting())
    }

    /// The real entry point: track a live session and confirm the tree roots
    /// at the shell's actual cwd.
    func testTrackLiveSessionRootsTreeAtShellCwd() {
        let (controller, window) = mountedController()
        let session = TerminalSession(config: AppConfig(), scale: 2)
        session.workingDirectory = tempDir
        window.contentView = session.view
        session.launch()
        defer { session.shutdown() }

        let exp = expectation(description: "tracker polled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exp.fulfill() }
        wait(for: [exp], timeout: 6)

        XCTAssertNotNil(session.currentDirectory())

        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.track(session: session)
        XCTAssertGreaterThan(controller.topLevelRowCountForTesting, 0)
    }

    // MARK: - markdown preview

    func testMarkdownRendersByDefaultWithRawToggle() throws {
        let (controller, _) = mountedController()
        let md = tempDir + "/Notes.md"
        try "# Title\n\nSome **bold** text\n".write(
            toFile: md, atomically: true, encoding: .utf8)
        controller.loadPreviewForTesting(URL(fileURLWithPath: md))
        // Rendered: markup is consumed by the renderer.
        XCTAssertFalse(controller.previewTextForTesting.contains("# Title"))
        XCTAssertTrue(controller.previewTextForTesting.contains("Title"))
        XCTAssertFalse(controller.markdownToggleHiddenForTesting)
        // Raw: original source comes back verbatim.
        controller.setMarkdownRenderedForTesting(false)
        XCTAssertTrue(controller.previewTextForTesting.contains("# Title"))
        XCTAssertTrue(controller.previewTextForTesting.contains("**bold**"))
    }

    func testMarkdownToggleHiddenForNonMarkdown() {
        let (controller, _) = mountedController()
        controller.loadPreviewForTesting(
            URL(fileURLWithPath: tempDir + "/Package.swift"))
        XCTAssertTrue(controller.markdownToggleHiddenForTesting)
    }

    // MARK: - search

    func testSearchFiltersListAndClearRestoresTree() {
        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.seedFileListCacheForTesting([
            "Sources/App.swift", "Sources/CodeView.swift", "README.md",
        ])
        controller.setSearchTextForTesting("codeview")
        controller.applySearchForTesting()
        XCTAssertEqual(controller.topLevelRowCountForTesting, 1)
        XCTAssertEqual(controller.cellTextForTesting(row: 0), "Sources/CodeView.swift")

        controller.setSearchTextForTesting("")
        controller.applySearchForTesting()
        XCTAssertEqual(controller.topLevelRowCountForTesting, 2)
    }

    // MARK: - changes page

    private func waitForCondition(
        _ description: String, timeout: TimeInterval = 10,
        condition: @escaping () -> Bool
    ) {
        let exp = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if condition() {
                timer.invalidate()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: timeout)
        // Always kill the timer: on timeout it would otherwise keep firing
        // into later tests, running stale closures against torn-down state.
        timer.invalidate()
    }

    func testChangesPageShowsNotARepoForPlainFolder() {
        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.switchPageForTesting(1)
        waitForCondition("git probe finished") {
            controller.headerTextForTesting == "Not a git repository"
        }
    }

    func testChangesPageListsLiveRepoChanges() throws {
        // Turn tempDir into a repo with one modified tracked file.
        func git(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try! p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
        }
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "Package.swift")
        git("commit", "-q", "-m", "init")
        try "// changed\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)

        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.switchPageForTesting(1)
        waitForCondition("changes loaded") {
            controller.topLevelRowCountForTesting == 1
        }
        XCTAssertEqual(controller.headerTextForTesting.hasSuffix("• master")
                           || controller.headerTextForTesting.hasSuffix("• main"),
                       true, controller.headerTextForTesting)
        XCTAssertEqual(controller.cellTextForTesting(row: 0), "Package.swift")
        XCTAssertEqual(controller.cellBadgeForTesting(row: 0), "M")
    }

    /// The footer picks up the branch without visiting the Changes page, and
    /// selecting a change row offers staging, which stages the file for real.
    func testBranchFooterAndStagingFlow() throws {
        func git(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try! p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
            return String(data: data, encoding: .utf8) ?? ""
        }
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "Package.swift")
        git("commit", "-q", "-m", "init")
        try "// changed\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)

        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        // No page switch: the footer probes git on the Files page too.
        waitForCondition("branch footer") {
            controller.branchFooterTextForTesting != nil
        }
        let branch = controller.branchFooterTextForTesting
        XCTAssertTrue(branch == "main" || branch == "master", branch ?? "")

        controller.switchPageForTesting(1)
        waitForCondition("changes loaded") {
            controller.topLevelRowCountForTesting == 1
        }
        XCTAssertTrue(controller.stageButtonHiddenForTesting)
        controller.selectRowForTesting(0)
        XCTAssertFalse(controller.stageButtonHiddenForTesting)
        XCTAssertEqual(controller.stageButtonTitleForTesting, "Stage")
        XCTAssertFalse(controller.stageAllButtonHiddenForTesting)

        controller.stageSelectedForTesting()
        waitForCondition("file staged") {
            git("diff", "--cached", "--name-only").contains("Package.swift")
        }
        // Visible feedback: the row stays selected, its badge goes solid,
        // and the button flips to Unstage.
        waitForCondition("button flipped") {
            controller.stageButtonTitleForTesting == "Unstage"
        }
        XCTAssertTrue(controller.cellBadgeIsSolidForTesting(row: 0))
    }

    /// Stage All stages modified and untracked files alike, and the stats
    /// line follows: untracked drains to zero, Added picks the files up.
    func testStageAllStagesEverything() throws {
        func git(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try! p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
            return String(data: data, encoding: .utf8) ?? ""
        }
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "Package.swift")
        git("commit", "-q", "-m", "init")
        try "// changed\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)
        try "let y = 2\n".write(
            toFile: tempDir + "/Sources/new.swift", atomically: true, encoding: .utf8)

        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.switchPageForTesting(1)
        waitForCondition("changes loaded") {
            controller.topLevelRowCountForTesting == 2
        }
        controller.stageAllForTesting()
        waitForCondition("all staged") {
            let staged = git("diff", "--cached", "--name-only")
            return staged.contains("Package.swift") && staged.contains("new.swift")
        }
        waitForCondition("changes refreshed") {
            controller.cellBadgeForTesting(row: 1) == "A"
        }
        XCTAssertEqual(controller.cellBadgeForTesting(row: 1), "A")
    }

    /// Stage all → type a message → Commit: the commit lands in git, the
    /// field clears, and the changes list drains.
    func testCommitFlow() throws {
        func git(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try! p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
            return String(data: data, encoding: .utf8) ?? ""
        }
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "Package.swift")
        git("commit", "-q", "-m", "init")
        try "// changed\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)

        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.switchPageForTesting(1)
        waitForCondition("changes loaded") {
            controller.topLevelRowCountForTesting == 1
        }
        // Disabled without a message, and still disabled once the message
        // exists but nothing is staged.
        XCTAssertFalse(controller.commitButtonEnabledForTesting)
        controller.setCommitMessageForTesting("test commit")
        XCTAssertFalse(controller.commitButtonEnabledForTesting)

        controller.stageAllForTesting()
        waitForCondition("commit enabled") {
            controller.commitButtonEnabledForTesting
        }
        controller.commitForTesting()
        waitForCondition("committed") {
            git("log", "--oneline", "-1").contains("test commit")
        }
        waitForCondition("changes drained") {
            controller.topLevelRowCountForTesting == 0
        }
        XCTAssertEqual(controller.commitMessageForTesting, "")
    }

    /// Selecting a change swaps the text preview for the diff table:
    /// combined and split modes render rows, and the font size adjusts.
    func testDiffViewerRendersCombinedAndSplit() throws {
        func git(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try! p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
        }
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "Package.swift")
        git("commit", "-q", "-m", "init")
        try "// changed\n".write(
            toFile: tempDir + "/Package.swift", atomically: true, encoding: .utf8)

        let (controller, _) = mountedController()
        controller.reRootForTesting(tempDir)
        controller.switchPageForTesting(1)
        waitForCondition("changes loaded") {
            controller.topLevelRowCountForTesting == 1
        }
        controller.selectRowForTesting(0)
        waitForCondition("diff loaded") { controller.showingDiffForTesting }
        XCTAssertEqual(controller.diffModeForTesting, 0)
        XCTAssertGreaterThan(controller.diffRowCountForTesting, 0)

        // Split mode pairs the changed line on a single row.
        controller.setDiffModeForTesting(1)
        XCTAssertEqual(controller.diffModeForTesting, 1)
        var paired = false
        for row in 0..<controller.diffRowCountForTesting {
            if controller.diffCellTextForTesting(row: row, column: 1) == "let x = 1",
               controller.diffCellTextForTesting(row: row, column: 3) == "// changed" {
                paired = true
            }
        }
        XCTAssertTrue(paired, "old and new versions should share a split row")

        let before = controller.diffFontSizeForTesting
        controller.adjustDiffFontForTesting(2)
        XCTAssertEqual(controller.diffFontSizeForTesting, before + 2)
        controller.adjustDiffFontForTesting(-2)
        XCTAssertEqual(controller.diffFontSizeForTesting, before)
    }
}
