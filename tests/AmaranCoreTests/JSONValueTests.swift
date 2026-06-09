import Foundation
import Testing
@testable import AmaranCore

struct JSONValueTests {
    @Test func accessorsReadNestedValues() throws {
        let data = """
        {"ok": true, "data": {"daemon": {"pid": 42}, "central_state": "poweredOn",
         "connected": false}}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(value["ok"]?.boolValue == true)
        #expect(value["data"]?["central_state"]?.stringValue == "poweredOn")
        #expect(value["data"]?["connected"]?.boolValue == false)
        #expect(value["data"]?["daemon"]?["pid"]?.intValue == 42)
        #expect(value["missing"] == nil)
    }
}
