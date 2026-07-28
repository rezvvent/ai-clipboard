import XCTest
@testable import AIClipboardCore

final class ProductCapabilitiesTests: XCTestCase {
    func testExtendedContentClassification() {
        let detector = ContentDetector()
        XCTAssertEqual(
            detector.detect(
                text: "Иван Петров\nivan@example.com\n+7 999 123-45-67",
                hasImage: false,
                files: []
            ),
            .contact
        )
        XCTAssertEqual(detector.detect(text: "name,amount\nA,10\nB,20", hasImage: false, files: []), .csv)
        XCTAssertEqual(detector.detect(text: "service:\n  host: db\n  port: 5432", hasImage: false, files: []), .yaml)
        XCTAssertEqual(detector.detect(text: "2026-07-29", hasImage: false, files: []), .date)
        XCTAssertEqual(detector.detect(text: "Москва, ул. Ленина, д. 12", hasImage: false, files: []), .address)
    }

    func testContextAwarePasteFormatsTable() {
        let engine = ContextAwarePasteEngine()
        let input = "city,revenue\nMoscow,10"
        XCTAssertTrue(engine.adapt(input, destination: .json).contains("\"city\""))
        XCTAssertTrue(engine.adapt(input, destination: .markdown).contains("| --- |"))
        XCTAssertEqual(engine.adapt(input, destination: .spreadsheet), "city\trevenue\nMoscow\t10")
    }

    func testSQLCopilotBlocksUnsafeMutation() {
        let analysis = SQLCopilot().analyze("DELETE FROM orders;")
        XCTAssertTrue(analysis.requiresConfirmation)
        XCTAssertEqual(analysis.referencedTables, ["orders"])
        XCTAssertTrue(analysis.findings.contains { $0.severity == .critical })
    }

    func testPipelineIsReproducible() {
        let pipeline = ClipboardPipeline(
            name: "Clean",
            steps: [
                .init(name: "Remove duplicates", operation: .removeDuplicates(columns: ["id"])),
                .init(name: "Rename", operation: .renameColumn(from: "city", to: "customer_city"))
            ]
        )
        let run = PipelineEngine().run(
            pipeline,
            input: "id,city\n1,Moscow\n1,Moscow\n2,Kazan"
        )
        XCTAssertEqual(run?.appliedSteps.count, 2)
        XCTAssertEqual(run?.output, "id,customer_city\n1,Moscow\n2,Kazan")
    }

    func testDatasetComparisonAndJoinSuggestion() {
        let old = CSVTable(text: "id,value\n1,A\n2,B")!
        let new = CSVTable(text: "id,value,new_column\n1,A,x\n3,C,y")!
        let difference = DatasetComparator().compare(old, new)
        XCTAssertEqual(difference.addedColumns, ["new_column"])
        XCTAssertGreaterThan(difference.addedRows, 0)

        let customers = CSVTable(text: "customer_id,city\n1,Moscow\n2,Kazan")!
        let orders = CSVTable(text: "customer_id,total\n1,10\n1,20\n2,30")!
        let suggestion = JoinIntelligence().suggestions(left: customers, right: orders).first
        XCTAssertEqual(suggestion?.leftColumn, "customer_id")
        XCTAssertEqual(suggestion?.relationship, "one-to-many")
    }

    func testSchemaAndValidation() {
        let schema = SchemaIntelligence().jsonSchema(from: #"{"id":1,"customer":{"email":"a@b.com"}}"#)
        XCTAssertTrue(schema?.contains("\"properties\"") == true)
        let table = CSVTable(text: "id,revenue\n1,10\n1,-5")!
        let issues = DataValidator().validate(table, rules: [
            .init(column: "id", kind: .unique),
            .init(column: "revenue", kind: .nonNegative)
        ])
        XCTAssertEqual(issues.count, 2)
    }
}
