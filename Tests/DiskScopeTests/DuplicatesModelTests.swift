import Darwin
import Foundation
import Testing
@testable import DiskScope

private func file(_ path: String, side: DupSide = .a, size: Int64 = 10, mtime: Int = 1_700_000_000) -> DupFile {
    DupFile(path: path, side: side, size: size, mtime: mtime, dev: 1, ino: UInt64(truncatingIfNeeded: path.hashValue))
}

private func group(_ files: [DupFile], digest: String = String(repeating: "ab", count: 32)) -> DupGroup {
    DupGroup(id: "\(files[0].size)-\(digest)", digest: digest, size: files[0].size, files: files)
}

/// Runs a script with /bin/bash (macOS bash 3.2) in a sandboxed environment: HOME and the
/// Trash folder point into the temp tree, so tests never touch the real Trash.
private func runScript(_ script: String, in t: TempTree, args: [String] = []) throws -> (status: Int32, output: String) {
    let scriptPath = t.path("remove-duplicates.sh")
    try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    t.dir("home"); t.dir("trash")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [scriptPath] + args
    p.currentDirectoryURL = URL(fileURLWithPath: t.root)
    p.environment = ["HOME": t.path("home"), "PATH": "/usr/bin:/bin", "DISKSCOPE_TRASH_DIR": t.path("trash"), "LANG": "en_US.UTF-8"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func exists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

@Suite("Duplicates model")
@MainActor
struct DuplicatesModelTests {
    @Test func endToEndRunAppliesTheDefaultPlan() async throws {
        let t = TempTree("dm-run")
        writeFile(t.path("A/keep me.txt"), "same bytes")
        writeFile(t.path("B/remove me.txt"), "same bytes")
        let model = DuplicatesModel()
        #expect(!model.canStart)
        model.set(.a, path: t.path("A"))
        model.set(.b, path: t.path("B"))
        #expect(model.canStart)
        model.start()
        #expect(model.phase == .running)
        #expect(!model.canStart)
        await model.runTask?.value

        #expect(model.phase == .done)
        let r = try #require(model.result)
        #expect(r.groups.count == 1)
        #expect(model.selection == r.groups[0].id)
        #expect(model.selectedGroup == r.groups[0])
        #expect(model.keepRule == .folderA)
        #expect(model.removals == [t.path("B/remove me.txt")])
        #expect(model.markedCount == 1)
        #expect(model.markedBytes == 10)
        #expect(model.totalWasted == 10)
        #expect(model.alert == nil)
    }

    @Test func oneFolderDefaultsToKeepingTheShortestPath() async throws {
        let t = TempTree("dm-one")
        writeFile(t.path("B/x.txt"), "copy")
        writeFile(t.path("B/sub/longer/x.txt"), "copy")
        let model = DuplicatesModel()
        model.set(.b, path: t.path("B"))   // a single folder in either slot searches within it
        model.start()
        await model.runTask?.value
        #expect(model.result?.twoFolders == false)
        #expect(model.keepRule == .shortestPath)
        #expect(model.removals == [t.path("B/sub/longer/x.txt")])
    }

    @Test func errorsAreReported() async throws {
        let model = DuplicatesModel()
        model.set(.a, path: "/definitely/not/here")
        model.start()
        await model.runTask?.value
        #expect(model.phase == .idle)
        #expect(model.alert?.title == "Can't search for duplicates")
    }

    @Test func cancelStopsTheRun() async throws {
        let t = TempTree("dm-cancel")
        writeFile(t.path("A/f"), "x")
        let model = DuplicatesModel()
        model.set(.a, path: t.path("A"))
        model.start()
        model.cancel()
        await model.runTask?.value
        #expect(model.phase == .idle)
        #expect(model.result == nil)
    }

    @Test func foldersCanBeSwappedAndCleared() {
        let model = DuplicatesModel()
        model.set(.a, path: "/tmp/one/")
        model.set(.b, path: "~/two")
        #expect(model.folderA == "/tmp/one")
        #expect(model.folderB == NSHomeDirectory() + "/two")
        model.swapFolders()
        #expect(model.folder(.a) == NSHomeDirectory() + "/two")
        #expect(model.folder(.b) == "/tmp/one")
        model.set(.b, path: nil)
        #expect(model.folderB == nil)
    }

    @Test func everySetKeepsAtLeastOneCopy() {
        let model = DuplicatesModel()
        let a = file("/a/f", side: .a), b = file("/b/f", side: .b)
        model.load(DupResult(groups: [group([a, b])], twoFolders: true, folders: ["/a", "/b"]))
        #expect(model.removals == ["/b/f"])

        model.setRemove(a, true)                       // would leave nothing kept
        #expect(model.alert?.title == "Every set keeps at least one copy")
        #expect(model.removals == ["/b/f"])

        model.alert = nil
        model.setRemove(b, false)
        #expect(model.removals.isEmpty)
        #expect(model.removalCount(in: model.result!.groups[0]) == 0)
        model.setRemove(a, true)                       // now b is kept, so a may go
        #expect(model.removals == ["/a/f"])
        #expect(model.isMarkedForRemoval(a))
        #expect(model.alert == nil)
    }

    @Test func changingTheRuleResetsOverrides() {
        let model = DuplicatesModel()
        let a = file("/a/f", side: .a, mtime: 100), b = file("/b/f", side: .b, mtime: 200)
        model.load(DupResult(groups: [group([a, b])], twoFolders: true, folders: ["/a", "/b"]))
        model.setRemove(b, false)
        #expect(model.removals.isEmpty)
        model.keepRule = .folderB
        #expect(model.removals == ["/a/f"])
        model.keepRule = .newest
        #expect(model.removals == ["/a/f"])
        model.keepRule = .oldest
        #expect(model.removals == ["/b/f"])
    }

    @Test func savedFilesAreNotExecutable() throws {
        let t = TempTree("dm-save")
        let model = DuplicatesModel()
        let url = URL(fileURLWithPath: t.path("remove-duplicates.sh"))
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o755])
        model.write("#!/bin/bash\n", to: url, what: "the script")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o644)
        #expect(try String(contentsOf: url, encoding: .utf8) == "#!/bin/bash\n")
        #expect(model.alert == nil)
        model.write("x", to: URL(fileURLWithPath: t.path("missing/dir/file")), what: "the CSV file")
        #expect(model.alert?.title == "Couldn't save the CSV file")
    }

    @Test func exportTextsReflectThePlan() {
        let model = DuplicatesModel()
        let a = file("/a/f", side: .a), b = file("/b/f", side: .b)
        model.load(DupResult(groups: [group([a, b])], twoFolders: true, folders: ["/a", "/b"]))
        #expect(model.scriptText().contains("remove_copy '/b/f' '/a/f' 10 "))
        #expect(model.csvText().contains(",B,remove,/b/f,"))
    }
}

@Suite("Keep rules")
struct KeepRuleTests {
    let a1 = file("/A/deeper/one", side: .a, mtime: 300)
    let a2 = file("/A/two", side: .a, mtime: 100)
    let b1 = file("/B/x", side: .b, mtime: 200)

    @Test func eachRulePicksTheExpectedCopy() {
        let g = group([a1, a2, b1])
        #expect(KeepRule.folderA.keeper(in: g) == a2)       // shortest path within A
        #expect(KeepRule.folderB.keeper(in: g) == b1)
        #expect(KeepRule.oldest.keeper(in: g) == a2)
        #expect(KeepRule.newest.keeper(in: g) == a1)
        #expect(KeepRule.shortestPath.keeper(in: g) == b1)
    }

    @Test func missingSideFallsBackToTheShortestPath() {
        let g = group([a1, a2])
        #expect(KeepRule.folderB.keeper(in: g) == a2)
    }

    @Test func tiesAreDeterministic() {
        let x = file("/A/b", mtime: 5), y = file("/A/a", mtime: 5)
        #expect(KeepRule.oldest.keeper(in: group([x, y])) == y)
        #expect(KeepRule.newest.keeper(in: group([y, x])) == y)
    }

    @Test func removalsCoverEveryCopyButTheKeeper() {
        let g1 = group([a1, a2, b1])
        let g2 = group([file("/A/z", side: .a, size: 7), file("/B/z", side: .b, size: 7)], digest: String(repeating: "cd", count: 32))
        #expect(KeepRule.folderA.removals(for: [g1, g2]) == ["/A/deeper/one", "/B/x", "/B/z"])
        #expect(KeepRule.defaultRule(twoFolders: true) == .folderA)
        #expect(KeepRule.defaultRule(twoFolders: false) == .shortestPath)
        #expect(!KeepRule.available(twoFolders: false).contains(.folderA))
        #expect(KeepRule.available(twoFolders: true) == KeepRule.allCases)
    }

    @Test func partitionNeverRemovesEveryCopy() {
        let g = group([a1, a2])
        let (keep, remove) = partition(g, removals: [a1.path, a2.path])
        #expect(keep == [a1])
        #expect(remove == [a2])
    }
}

@Suite("Removal script")
struct RemovalScriptTests {
    static let nasty = [
        "plain", "with space", "it's", "\"double\"", "$(touch PWNED1)", "`touch PWNED2`",
        "semi;colon && echo hi", "new\nline", "tab\there", "back\\slash", "dollar $HOME", "glob *",
        "-dash", "émoji 🎉 日本語", "'; touch PWNED3; '",
    ]

    @Test func shellQuotingRoundTripsThroughBash() throws {
        for s in Self.nasty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "printf '%s' \(RemovalScript.shellQuote(s))"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(String(decoding: out, as: UTF8.self) == s, "round trip of \(s.debugDescription)")
        }
        #expect(RemovalScript.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func onlyMarkedCopiesAreRemovedAndCommentsStayOnOneLine() {
        let keep = file("/A/keep", side: .a)
        let gone = file("/B/evil\nrm -rf ~\u{202E}txt.app", side: .b)
        let untouched = group([file("/A/u", size: 3), file("/B/u", side: .b, size: 3)], digest: String(repeating: "ef", count: 32))
        let script = RemovalScript.make(groups: [group([keep, gone]), untouched], removals: [gone.path],
                                        generated: Date(timeIntervalSince1970: 0), folders: ["/A", "/B\nx"])
        let calls = script.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("remove_copy ") }
        #expect(calls.count == 1)
        #expect(script.contains("remove_copy '/B/evil\nrm -rf ~\u{202E}txt.app' '/A/keep' 10 \(String(repeating: "ab", count: 32))"))
        #expect(!script.contains("remove_copy '/A/keep'"))
        #expect(!script.contains("'/A/u'") && !script.contains("'/B/u'"))   // sets with nothing to remove are left out
        #expect(script.contains("# Set 1 of 1 · "))
        #expect(script.contains("#   keep:   /A/keep\n"))
        #expect(script.contains("#   remove: /B/evil\u{FFFD}rm -rf ~\u{FFFD}txt.app\n"))
        #expect(script.contains("# Folder B: /B\u{FFFD}x\n"))
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("Nothing is deleted permanently"))
    }

    @Test func aSetMarkedEntirelyStillKeepsOneCopy() {
        let x = file("/A/x"), y = file("/B/y", side: .b)
        let script = RemovalScript.make(groups: [group([x, y])], removals: [x.path, y.path], generated: Date(), folders: [])
        #expect(script.contains("remove_copy '/B/y' '/A/x' "))
        #expect(!script.contains("remove_copy '/A/x'"))
    }

    /// Builds a real duplicate result and plan for files in A (kept) and B (removed).
    private func plan(_ t: TempTree, names: [String]) throws -> (DupResult, Set<String>) {
        for (i, name) in names.enumerated() {
            let data = noise(3000 + i, seed: UInt64(i + 40))
            writeFile(t.path("A/\(name)"), data)
            writeFile(t.path("B/\(name)"), data)
        }
        let r = try findDuplicates(t.path("A"), t.path("B"))
        #expect(r.groups.count == names.count)
        return (r, KeepRule.folderA.removals(for: r.groups))
    }

    @Test func dryRunChangesNothingAndApplyMovesOnlyMarkedCopies() throws {
        let t = TempTree("rs-run")
        let names = Self.nasty.filter { !$0.contains("/") }
        let (r, removals) = try plan(t, names: names)
        let script = RemovalScript.make(groups: r.groups, removals: removals, generated: Date(), folders: r.folders)

        let dry = try runScript(script, in: t)
        #expect(dry.status == 0, "\(dry.output)")
        #expect(dry.output.contains("Dry run: \(names.count) would be moved to the Trash, 0 skipped."))
        for name in names {
            #expect(exists(t.path("A/\(name)")))
            #expect(exists(t.path("B/\(name)")))
        }

        let applied = try runScript(script, in: t, args: ["--apply"])
        #expect(applied.status == 0, "\(applied.output)")
        #expect(applied.output.contains("Done: \(names.count) moved to the Trash, 0 skipped."))
        for name in names {
            #expect(exists(t.path("A/\(name)")), "kept copy \(name.debugDescription)")
            #expect(!exists(t.path("B/\(name)")), "removed copy \(name.debugDescription)")
            #expect(exists(t.path("trash/\(name)")), "in trash \(name.debugDescription)")
        }
        // No injected command ran.
        for marker in ["PWNED1", "PWNED2", "PWNED3"] {
            #expect(!exists(t.path(marker)) && !exists(t.path("home/\(marker)")))
        }
    }

    @Test func changedFilesAreSkipped() throws {
        let t = TempTree("rs-skip")
        let (r, removals) = try plan(t, names: ["changed", "kept-gone", "now-link", "fine", "collide"])
        let script = RemovalScript.make(groups: r.groups, removals: removals, generated: Date(), folders: r.folders)

        // Same size, different contents.
        var data = try Data(contentsOf: URL(fileURLWithPath: t.path("B/changed")))
        data[0] ^= 0xFF
        try data.write(to: URL(fileURLWithPath: t.path("B/changed")))
        // The copy that was going to be kept is gone.
        try FileManager.default.removeItem(atPath: t.path("A/kept-gone"))
        // The file to remove was replaced by a symlink to the kept copy.
        try FileManager.default.removeItem(atPath: t.path("B/now-link"))
        t.symlink("B/now-link", to: t.path("A/now-link"))
        // Something with the same name is already in the Trash.
        t.dir("trash")
        writeFile(t.path("trash/collide"), "older trash")

        let out = try runScript(script, in: t, args: ["--apply"])
        #expect(out.status == 0, "\(out.output)")
        #expect(out.output.contains("SKIP: \(t.path("B/changed")) (its contents changed)"))
        #expect(out.output.contains("SKIP: \(t.path("B/kept-gone")) (the copy being kept: it no longer exists or is not a regular file)"))
        #expect(out.output.contains("SKIP: \(t.path("B/now-link")) (it is now a symbolic link)"))
        #expect(out.output.contains("Done: 2 moved to the Trash, 3 skipped."))
        #expect(exists(t.path("B/changed")) && exists(t.path("B/kept-gone")) && exists(t.path("B/now-link")))
        #expect(!exists(t.path("B/fine")) && exists(t.path("trash/fine")))
        #expect(try String(contentsOfFile: t.path("trash/collide"), encoding: .utf8) == "older trash")
        #expect(exists(t.path("trash/collide (2)")))
    }

    @Test func unknownArgumentsAreRejected() throws {
        let t = TempTree("rs-args")
        let script = RemovalScript.make(groups: [], removals: [], generated: Date(), folders: [])
        let out = try runScript(script, in: t, args: ["--yes"])
        #expect(out.status == 2)
        #expect(out.output.contains("usage:"))
        #expect(try runScript(script, in: t).status == 0)
    }
}

@Suite("CSV")
struct CSVTests {
    @Test func fieldsAreQuotedOnlyWhenNeeded() {
        #expect(CSV.field("plain") == "plain")
        #expect(CSV.field("") == "")
        #expect(CSV.field("a,b") == "\"a,b\"")
        #expect(CSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSV.field("two\nlines") == "\"two\nlines\"")
        #expect(CSV.field("cr\r\nlf") == "\"cr\r\nlf\"")
        #expect(CSV.field(" padded") == "\" padded\"")
        #expect(CSV.field("/Users/me/My File.txt") == "/Users/me/My File.txt")
        #expect(CSV.field("日本語") == "日本語")
    }

    @Test func formulasAreNeutralised() {
        #expect(CSV.field("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(CSV.field("+1") == "'+1")
        #expect(CSV.field("-2") == "'-2")
        #expect(CSV.field("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSV.field("\tx") == "'\tx")
        #expect(CSV.field("\rx") == "\"'\rx\"")
        #expect(CSV.field("a=b") == "a=b")
        #expect(CSV.number(-2) == "-2")
    }

    @Test func rowsEndWithCRLF() {
        #expect(CSV.row(["a", "b,c"]) == "a,\"b,c\"\r\n")
        #expect(CSV.row(encoded: ["1", "x"]) == "1,x\r\n")
        #expect(CSV.document(header: ["h1", "h2"], rows: [["1", "2"], ["3", "=4"]]) == "h1,h2\r\n1,2\r\n3,'=4\r\n")
    }

    @Test func duplicatesExportHasOneRowPerCopy() {
        let a = DupFile(path: "/A/one, two.txt", side: .a, size: 5, mtime: 0, dev: 1, ino: 1)
        let b = DupFile(path: "/B/=cmd.txt", side: .b, size: 5, mtime: 86_400, dev: 1, ino: 2)
        let g = DupGroup(id: "5-abc", digest: "abc", size: 5, files: [a, b])
        let csv = DuplicatesCSV.make(groups: [g], removals: [b.path])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "set,sha256,size_bytes,copies,wasted_bytes,side,plan,path,modified")
        #expect(lines[1] == "1,abc,5,2,5,A,keep,\"/A/one, two.txt\",1970-01-01T00:00:00Z")
        #expect(lines[2] == "1,abc,5,2,5,B,remove,/B/=cmd.txt,1970-01-02T00:00:00Z")
        #expect(lines.count == 4 && lines[3].isEmpty)
    }
}
