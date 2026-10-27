import XCTest
@testable import CCEnvCore

final class FingerprintTests: XCTestCase {
    let hex = { (c: Character) in String(repeating: c, count: 64) }

    func testClaudeCodeItems() {
        let cfg: [String: Any] = [
            "userID": hex("a"),
            "machineID": "not-hex",
            "firstStartTime": "2026-01-01T00:00:00.000Z",
            "oauthAccount": ["accountUuid": "u-1", "emailAddress": "me@example.com", "accessToken": "secret"],
        ]
        let items = Fingerprints.claudeCodeItems(cfg, file: NSHomeDirectory() + "/.claude.json")
        let byKey = Dictionary(uniqueKeysWithValues: items.map { (String($0.id.split(separator: "#")[1]), $0) })
        XCTAssertEqual(byKey["userID"]?.resettable, true)
        XCTAssertEqual(byKey["machineID"]?.resettable, false)
        XCTAssertEqual(byKey["oauthAccount.emailAddress"]?.sensitive, true)
        XCTAssertEqual(byKey["firstStartTime"]?.masked, false)
        XCTAssertEqual(items.first?.source, "~/.claude.json")
        XCTAssertFalse(items.contains { ($0.value ?? "").contains("secret") })
    }

    func testDiff() {
        func fp(_ pairs: [(String, String)]) -> Fingerprint {
            Fingerprint(tool: "ccenv", kind: "fingerprint", schema: 1, version: "0", generatedAt: "", host: "",
                        items: pairs.map { FingerprintItem(id: $0.0, group: "g", label: $0.0, value: $0.1, source: "") })
        }
        let rows = Fingerprints.diff(fp([("x", "1"), ("y", "2"), ("z", "3")]), fp([("x", "1"), ("y", "9"), ("w", "4")]))
        let status = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
        XCTAssertEqual(status, ["x": .same, "y": .changed, "w": .added, "z": .removed])
    }

    func testMask() {
        XCTAssertEqual(Fingerprints.mask(hex("b")), "bbbbbbbb…bbbb")
        XCTAssertEqual(Fingerprints.mask("host.local", masked: false), "host.local")
        XCTAssertEqual(Fingerprints.mask("me@example.com", sensitive: true), "m***@example.com")
        XCTAssertEqual(Fingerprints.mask(nil), "—")
    }

    func testRegenerateKeepsFormatting() throws {
        let text = "{\n  \"numStartups\": 3,\n  \"userID\": \"\(hex("a"))\",\n  \"machineID\":\"\(hex("b"))\",\n  \"summonSidKey\": \"short\"\n}\n"
        var n = 0
        let (out, changes) = try Fingerprints.regenerate(in: text) { n += 1; return String(repeating: Character(String(n)), count: 64) }
        XCTAssertEqual(changes.map(\.key), ["userID", "machineID"])
        XCTAssertEqual(out, text.replacingOccurrences(of: hex("a"), with: hex("1")).replacingOccurrences(of: hex("b"), with: hex("2")))
    }

    func testRegenerateIdsWritesBackupAndKeepsMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccenv-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        try Data("{\"userID\": \"\(hex("c"))\", \"machineID\": \"\(hex("d"))\"}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let results = try Fingerprints.regenerateIds(files: [file.path], backupTo: dir.appendingPathComponent("bak"))
        XCTAssertEqual(results.first?.changes.count, 2)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: String]
        XCTAssertNotEqual(after["userID"], hex("c"))
        XCTAssertTrue(Fingerprints.isHex64(after["userID"]!))
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: results[0].backup!))) as! [String: String]
        XCTAssertEqual(backup["userID"], hex("c"))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

    func testSnapshotRoundTripReadsCLIFormat() throws {
        // CLI 写的快照：键顺序不同、note 为 null，也要能读。
        let json = #"{"tool":"ccenv","kind":"fingerprint","schema":1,"version":"0.4.0","generatedAt":"2026-10-27T07:55:22.631Z","host":"h","items":[{"id":"~/.claude.json#userID","group":"g","label":"设备 ID (userID)","value":"x","source":"~/.claude.json","note":null,"resettable":true,"masked":true,"sensitive":false}]}"#
        let fp = try JSONDecoder().decode(Fingerprint.self, from: Data(json.utf8))
        XCTAssertEqual(fp.items.first?.resettable, true)
        let again = try JSONDecoder().decode(Fingerprint.self, from: Fingerprints.encode(fp))
        XCTAssertEqual(again.items, fp.items)
    }

    func testClaudeCodeProcessMatching() {
        XCTAssertTrue(Fingerprints.isClaudeCodeProcess("/Users/a/.local/share/claude/versions/2.1.311 --session-id x"))
        XCTAssertTrue(Fingerprints.isClaudeCodeProcess("node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"))
        XCTAssertTrue(Fingerprints.isClaudeCodeProcess("/Users/a/.local/bin/claude daemon run"))
        XCTAssertFalse(Fingerprints.isClaudeCodeProcess("/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertFalse(Fingerprints.isClaudeCodeProcess("vim claude.md"))
    }

    func testVersionCompareAndReleaseDecode() throws {
        XCTAssertEqual(UpdateCheck.compare("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateCheck.compare("v1.2.3", "1.2.3"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.2", "1.2.1"), .orderedAscending)
        let json = #"{"tag_name":"v0.4.0","html_url":"https://github.com/kadaliao/ccenv/releases/tag/v0.4.0","body":"x","assets":[{"name":"ccenv-0.4.0.dmg","browser_download_url":"https://e/a.dmg","size":1},{"name":"ccenv-0.4.0-macos.zip","browser_download_url":"https://e/a.zip","size":2}]}"#
        let r = try UpdateCheck.decode(Data(json.utf8))
        XCTAssertEqual(r.version, "0.4.0")
        XCTAssertEqual(r.macZip?.name, "ccenv-0.4.0-macos.zip")
    }
}
