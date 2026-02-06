import XCTest
@testable import BetterSiri

final class MarkdownParserTests: XCTestCase {
    func testInlineDollarMathInsideSentence() throws {
        let blocks = MarkdownParser.parse("Area is $a^2$ units.")
        let runs = try XCTUnwrap(paragraphRuns(from: blocks))

        XCTAssertEqual(runs, [
            .styled(style: .normal, text: "Area is "),
            .math(latex: "a^2"),
            .styled(style: .normal, text: " units.")
        ])
    }

    func testEscapedDollarRemainsText() throws {
        let blocks = MarkdownParser.parse(#"Price is \$5.00 today."#)
        let runs = try XCTUnwrap(paragraphRuns(from: blocks))

        XCTAssertFalse(runs.contains(where: isMathRun))
        XCTAssertEqual(plainText(from: runs), "Price is $5.00 today.")
    }

    func testInlineParenthesisMathParses() throws {
        let blocks = MarkdownParser.parse(#"Compute \(x+1\) now."#)
        let runs = try XCTUnwrap(paragraphRuns(from: blocks))

        XCTAssertTrue(runs.contains(.math(latex: "x+1")))
    }

    func testDollarMathBlockParsesSameLineAndTrailingText() throws {
        let blocks = MarkdownParser.parse("$$x^2$$ trailing")
        XCTAssertEqual(blocks.count, 2)

        guard case .mathBlock(let latex) = blocks[0].kind else {
            return XCTFail("Expected first block to be mathBlock")
        }
        XCTAssertEqual(latex, "x^2")

        let trailingRuns = try XCTUnwrap(paragraphRuns(from: [blocks[1]]))
        XCTAssertEqual(plainText(from: trailingRuns), "trailing")
    }

    func testBackslashBracketMathBlockParsesMultiLine() throws {
        let blocks = MarkdownParser.parse(
            #"""
\[
x^2 + y^2
\]
"""#
        )

        XCTAssertEqual(blocks.count, 1)
        guard case .mathBlock(let latex) = blocks[0].kind else {
            return XCTFail("Expected a mathBlock")
        }
        XCTAssertEqual(latex, "x^2 + y^2")
    }

    func testUnclosedMathDelimitersRemainText() throws {
        let inlineBlocks = MarkdownParser.parse("Value is $x")
        let inlineRuns = try XCTUnwrap(paragraphRuns(from: inlineBlocks))
        XCTAssertFalse(inlineRuns.contains(where: isMathRun))
        XCTAssertEqual(plainText(from: inlineRuns), "Value is $x")

        let blockBlocks = MarkdownParser.parse("$$ x^2")
        XCTAssertEqual(blockBlocks.count, 1)
        XCTAssertFalse(
            blockBlocks.contains { block in
                if case .mathBlock = block.kind { return true }
                return false
            }
        )
        let blockRuns = try XCTUnwrap(paragraphRuns(from: blockBlocks))
        XCTAssertEqual(plainText(from: blockRuns), "$$ x^2")
    }

    func testGFMTableParsesWithAlignment() throws {
        let blocks = MarkdownParser.parse(
            """
            | Name | Qty | Ratio |
            | :--- | :---: | ---: |
            | A | 1 | 2.0 |
            | B | 2 | 3.5 |
            """
        )

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let header, let alignments, let rows) = blocks[0].kind else {
            return XCTFail("Expected table block")
        }

        XCTAssertEqual(alignments, [.left, .center, .right])
        XCTAssertEqual(header.count, 3)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(plainText(from: header[0]), "Name")
        XCTAssertEqual(plainText(from: rows[1][2]), "3.5")
    }

    func testTableEscapedPipeStaysInCellText() throws {
        let blocks = MarkdownParser.parse(
            #"""
| Col |
| --- |
| a \| b |
"""#
        )

        guard case .table(_, _, let rows) = blocks.first?.kind else {
            return XCTFail("Expected table block")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(plainText(from: rows[0][0]), "a | b")
    }

    func testInvalidSeparatorDoesNotCreateTable() {
        let blocks = MarkdownParser.parse(
            """
            | Name | Qty |
            | --- | xx- |
            | A | 1 |
            """
        )

        let hasTable = blocks.contains { block in
            if case .table = block.kind { return true }
            return false
        }
        XCTAssertFalse(hasTable)
    }

    private func paragraphRuns(from blocks: [MarkdownBlock]) -> [MarkdownInlineRun]? {
        guard blocks.count == 1, case .paragraph(let runs) = blocks[0].kind else { return nil }
        return runs
    }

    private func plainText(from runs: [MarkdownInlineRun]) -> String {
        runs.reduce(into: "") { result, run in
            if case .styled(_, let text) = run {
                result.append(text)
            }
        }
    }

    private func isMathRun(_ run: MarkdownInlineRun) -> Bool {
        if case .math = run { return true }
        return false
    }
}
