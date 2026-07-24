import XCTest
@testable import InfinittyKit

final class PaneTodosTests: XCTestCase {

    func testParserAcceptsClaudeTodoWriteShape() {
        let json = """
        [{"content":"Read the file","status":"completed","activeForm":"Reading"},
         {"content":"Fix the bug","status":"in_progress","activeForm":"Fixing"},
         {"content":"Run tests","status":"pending","activeForm":"Running"}]
        """.replacingOccurrences(of: "\n", with: "")
        let todos = PaneTodoParser.parse(json)
        XCTAssertEqual(todos, [
            PaneTodo(text: "Read the file", done: true, active: false),
            PaneTodo(text: "Fix the bug", done: false, active: true),
            PaneTodo(text: "Run tests", done: false, active: false),
        ])
    }

    func testParserAcceptsGenericAndStringShapes() {
        XCTAssertEqual(
            PaneTodoParser.parse(#"[{"text":"a","done":true},"b"]"#),
            [
                PaneTodo(text: "a", done: true, active: false),
                PaneTodo(text: "b", done: false, active: false),
            ])
        XCTAssertNil(PaneTodoParser.parse("not json"))
        XCTAssertNil(PaneTodoParser.parse(#"{"an":"object"}"#))
        XCTAssertEqual(PaneTodoParser.parse("[]"), [])
    }

    func testEncodeRoundTrips() {
        let todos = [PaneTodo(text: "x", done: true, active: false)]
        XCTAssertEqual(PaneTodoParser.parse(PaneTodoParser.encode(todos)), todos)
    }

    func testHeaderShowsChecklistOnlyWhenTodosExistAndReportsProgress() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        XCTAssertFalse(header.todoButtonIsVisibleForTesting)
        header.setTodoProgress(total: 3, done: 1)
        XCTAssertTrue(header.todoButtonIsVisibleForTesting)
        XCTAssertEqual(header.todoTooltipForTesting, "Agent todos: 1/3 done")
        header.setTodoProgress(total: 0, done: 0)
        XCTAssertFalse(header.todoButtonIsVisibleForTesting)
    }

    func testTodoListViewBuildsOneRowPerItem() {
        let view = PaneTodoListView(todos: [
            PaneTodo(text: "one", done: true, active: false),
            PaneTodo(text: "two", done: false, active: true),
        ])
        XCTAssertEqual(view.rowCountForTesting, 2)
    }

    func testTerminalViewTracksTodosAndTogglesHeaderState() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setTodos([PaneTodo(text: "one", done: false, active: true)])
        XCTAssertEqual(view.todosForTesting.count, 1)
        XCTAssertTrue(view.paneHeader.todoButtonIsVisibleForTesting)
        view.setTodos([])
        XCTAssertFalse(view.paneHeader.todoButtonIsVisibleForTesting)
    }
}
