import Foundation
import Testing
@testable import DiskScope

@Suite("Sunburst")
struct SunburstTests {
    private let disk: (FileNode) -> Int64 = { $0.diskSize }
    private let eps = 1e-9

    @Test func spansAreProportionalToSize() {
        let root = makeTree(rootName: "/r", ["a:500", "b:300", "c:200"])
        let segs = SunburstLayout.make(center: root, size: disk)
        #expect(segs.map(\.name) == ["a", "b", "c"])   // largest first, clockwise from the top
        for s in segs {
            #expect(abs(s.span - Double(s.bytes) / 1000) < eps)
            #expect(s.depth == 1)
            #expect(s.kind == .item)
        }
        #expect(segs[0].start == 0)
        #expect(abs(segs[1].start - segs[0].end) < eps)
        #expect(abs(segs[2].end - 1) < eps)
    }

    @Test func sortsBySizeNotTheAppsSortOrder() {
        let root = makeTree(rootName: "/r", ["a:10", "z:900", "m:90"])
        #expect(SunburstLayout.make(center: root, size: disk).map(\.name) == ["z", "m", "a"])
    }

    @Test func childrenStartAtTheirParentAndStayInside() {
        let root = makeTree(rootName: "/r", ["a/x:300", "a/y:100", "a/sub/z:50", "b/w:400", "b/v:150", "f:10"])
        let segs = SunburstLayout.make(center: root, size: disk)
        for s in segs where s.depth > 1 {
            guard let node = s.node, let parentNode = node.parent,
                  let p = segs.first(where: { $0.node === parentNode }) else {
                Issue.record("no parent slice for \(s.name)"); continue
            }
            #expect(p.depth == s.depth - 1)
            #expect(s.start >= p.start - eps && s.end <= p.end + eps)
        }
        // The largest child of each folder starts exactly where the folder starts.
        let a = segs.first { $0.name == "a" }!
        let x = segs.first { $0.name == "x" }!
        #expect(abs(x.start - a.start) < eps)
        let sub = segs.first { $0.name == "sub" }!
        let z = segs.first { $0.name == "z" }!
        #expect(z.depth == 3 && abs(z.start - sub.start) < eps)
    }

    @Test func descendantsShareTheTopLevelColor() {
        let root = makeTree(rootName: "/r", ["a/x/y:300", "b/w:200"])
        let segs = SunburstLayout.make(center: root, size: disk)
        let byName = Dictionary(uniqueKeysWithValues: segs.map { ($0.name, $0) })
        #expect(byName["a"]!.colorIndex == 0 && byName["x"]!.colorIndex == 0 && byName["y"]!.colorIndex == 0)
        #expect(byName["b"]!.colorIndex == 1 && byName["w"]!.colorIndex == 1)
    }

    @Test func depthIsLimited() {
        let root = makeTree(rootName: "/r", ["a/b/c/d/e/f/g:100"])
        let three = SunburstLayout.make(center: root, size: disk, maxDepth: 3)
        #expect(three.map(\.depth).max() == 3)
        #expect(three.count == 3)
        let all = SunburstLayout.make(center: root, size: disk, maxDepth: 10)
        #expect(all.map(\.depth).max() == 7)
        #expect(SunburstLayout.make(center: root, size: disk).map(\.depth).max() == SunburstLayout.defaultMaxDepth)
    }

    @Test func tinyChildrenAreMergedIntoOneSlice() {
        let root = makeTree(rootName: "/r", ["big:1000"] + (0..<50).map { "t\($0):1" })
        let segs = SunburstLayout.make(center: root, size: disk, minSpan: 0.0025)
        #expect(segs.count == 2)
        #expect(segs[0].name == "big")
        let merged = segs[1]
        #expect(merged.kind == .smaller(50))
        #expect(merged.bytes == 50)
        #expect(merged.node == nil)
        #expect(merged.parent === root)
        #expect(abs(merged.start - segs[0].end) < eps)
        #expect(abs(merged.span - 50.0 / 1050) < eps)
        #expect(merged.name == "50 smaller items")
    }

    @Test func mergedSliceTooThinToSeeIsDropped() {
        let root = makeTree(rootName: "/r", ["big:100000", "tiny:1"])
        let segs = SunburstLayout.make(center: root, size: disk)
        #expect(segs.map(\.name) == ["big"])
    }

    @Test func hiddenSpaceIsTheLastTopLevelSlice() {
        let root = makeTree(rootName: "/", ["a:200", "b:100"])
        let segs = SunburstLayout.make(center: root, size: disk, hidden: 100)
        let h = segs.last!
        #expect(h.kind == .hidden)
        #expect(h.depth == 1)
        #expect(h.bytes == 100)
        #expect(abs(h.start - 0.75) < eps && abs(h.end - 1) < eps)
        #expect(abs(segs[0].span - 0.5) < eps)   // a is 200 of 400
        #expect(segs.filter { $0.kind == .hidden }.count == 1)
    }

    @Test func emptyOrZeroSizedCenter() {
        let empty = FileNode(name: "/e", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0,
                             mtime: 0, parent: nil)
        #expect(SunburstLayout.make(center: empty, size: disk).isEmpty)
        let zeros = makeTree(rootName: "/z", ["a:0", "b/c:0"])
        #expect(SunburstLayout.make(center: zeros, size: disk).isEmpty)
        // Only hidden space: one slice around the whole circle.
        let onlyHidden = SunburstLayout.make(center: empty, size: disk, hidden: 42)
        #expect(onlyHidden.count == 1)
        #expect(onlyHidden[0].kind == .hidden && onlyHidden[0].start == 0 && onlyHidden[0].end == 1)
        #expect(SunburstLayout.make(center: zeros, size: disk, maxDepth: 0).isEmpty)
    }

    @Test func segmentCountIsCapped() {
        let root = makeTree(rootName: "/r", (0..<100).map { "f\($0):10" })
        let segs = SunburstLayout.make(center: root, size: disk, maxSegments: 10)
        #expect(segs.count == 10)
        #expect(segs.last!.kind == .smaller(91))   // 9 drawn + the rest merged
        #expect(abs(segs.last!.end - 1) < eps)

        let withHidden = SunburstLayout.make(center: root, size: disk, hidden: 100, maxSegments: 10)
        #expect(withHidden.count == 10)
        #expect(withHidden.last!.kind == .hidden)
    }

    @Test func capKeepsInnerRingsAndTrimsOuterOnes() {
        // Breadth-first: every top-level folder gets its slice before any grandchild is drawn.
        var specs: [String] = []
        for d in 0..<5 { for f in 0..<20 { specs.append("d\(d)/f\(f):10") } }
        let root = makeTree(rootName: "/r", specs)
        let segs = SunburstLayout.make(center: root, size: disk, maxSegments: 12)
        #expect(segs.count <= 12)
        #expect(segs.filter { $0.depth == 1 }.count == 5)
    }

    @Test func hugeFoldersStayCheap() {
        let root = FileNode(name: "/big", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0,
                            mtime: 0, parent: nil)
        root.children = (0..<150_000).map {
            FileNode(name: "f\($0)", isDirectory: false, isSymlink: false, diskSize: Int64($0 % 97 + 1),
                     apparentSize: 1, mtime: 0, parent: root)
        }
        FileNode.aggregateTotals(from: root)
        let start = Date()
        let segs = SunburstLayout.make(center: root, size: disk)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(segs.count == 1)                      // all far thinner than minSpan
        #expect(segs[0].kind == .smaller(150_000))
        #expect(abs(segs[0].end - 1) < 1e-6)
    }

    @Test func namesAreDisplaySafe() {
        let root = makeTree(rootName: "/r", ["evil\u{202E}txt.app:10"])
        #expect(SunburstLayout.make(center: root, size: disk)[0].name == "evil\u{FFFD}txt.app")
    }

    @Test func usesTheGivenSizeFunction() {
        let root = FileNode(name: "/r", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0,
                            mtime: 0, parent: nil)
        root.children = [
            FileNode(name: "sparse", isDirectory: false, isSymlink: false, diskSize: 10, apparentSize: 900, mtime: 0, parent: root),
            FileNode(name: "dense", isDirectory: false, isSymlink: false, diskSize: 90, apparentSize: 100, mtime: 0, parent: root),
        ]
        FileNode.aggregateTotals(from: root)
        #expect(SunburstLayout.make(center: root, size: { $0.diskSize }).map(\.name) == ["dense", "sparse"])
        #expect(SunburstLayout.make(center: root, size: { $0.apparentSize }).map(\.name) == ["sparse", "dense"])
    }

    // MARK: Geometry & hit testing

    @Test func geometryFitsTheView() {
        let g = SunburstGeometry(size: CGSize(width: 300, height: 200), depth: 4)
        #expect(g.center == CGPoint(x: 150, y: 100))
        #expect(g.radius == 88)
        #expect(abs(g.inner - 88 * 0.22) < 1e-9)
        #expect(abs(g.outerRadius(depth: 4) - g.radius) < 1e-9)
        #expect(abs(g.innerRadius(depth: 1) - g.inner) < 1e-9)
        let tiny = SunburstGeometry(size: .zero, depth: 0)
        #expect(tiny.radius == 1 && tiny.depth == 1)
    }

    @Test func hitTestingFindsRingsAndAngles() {
        // a (dir, 50%) = x 30% + y 20%; b 25%; c 25%.
        let root = makeTree(rootName: "/r", ["a/x:30", "a/y:20", "b:25", "c:25"])
        let segs = SunburstLayout.make(center: root, size: disk)
        let g = SunburstGeometry(size: CGSize(width: 200, height: 200), depth: segs.map(\.depth).max()!)
        func name(_ hit: SunburstHit) -> String? {
            if case .segment(let i) = hit { return segs[i].name }
            return nil
        }
        func at(_ fraction: Double, ring: Int) -> CGPoint {
            g.point(fraction: fraction, radius: g.innerRadius(depth: ring) + g.ring / 2)
        }
        let c = g.center
        #expect(SunburstLayout.hitTest(segs, point: c, geometry: g) == .center)
        #expect(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x + g.inner / 2, y: c.y), geometry: g) == .center)

        // Ring 1: top, right, bottom, left.
        #expect(name(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x, y: c.y - (g.inner + g.ring / 2)), geometry: g)) == "a")
        #expect(name(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x + g.inner + g.ring / 2, y: c.y), geometry: g)) == "a")
        #expect(name(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x, y: c.y + g.inner + g.ring / 2), geometry: g)) == "b")
        #expect(name(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x - (g.inner + g.ring / 2), y: c.y), geometry: g)) == "c")

        // Ring 2 inside a: x covers [0, 0.3), y [0.3, 0.5).
        #expect(name(SunburstLayout.hitTest(segs, point: at(0.1, ring: 2), geometry: g)) == "x")
        #expect(name(SunburstLayout.hitTest(segs, point: at(0.4, ring: 2), geometry: g)) == "y")
        #expect(SunburstLayout.hitTest(segs, point: at(0.6, ring: 2), geometry: g) == .none)   // b is a file

        // Outside the chart.
        #expect(SunburstLayout.hitTest(segs, point: CGPoint(x: c.x + g.radius + 1, y: c.y), geometry: g) == .none)
        #expect(SunburstLayout.hitTest(segs, point: CGPoint(x: 0, y: 0), geometry: g) == .none)
        #expect(SunburstLayout.hitTest([], point: at(0.1, ring: 1), geometry: g) == .none)
    }

    @Test func pointAndHitTestAgree() {
        let root = makeTree(rootName: "/r", (0..<7).map { "f\($0):\(10 + $0)" })
        let segs = SunburstLayout.make(center: root, size: disk)
        let g = SunburstGeometry(size: CGSize(width: 400, height: 400), depth: 1)
        for (i, s) in segs.enumerated() {
            let p = g.point(fraction: s.mid, radius: g.inner + g.ring / 2)
            #expect(SunburstLayout.hitTest(segs, point: p, geometry: g) == .segment(i))
        }
    }

    @Test func pathsCoverTheirSlice() {
        let root = makeTree(rootName: "/r", ["a:75", "b:25"])
        let segs = SunburstLayout.make(center: root, size: disk)
        let g = SunburstGeometry(size: CGSize(width: 200, height: 200), depth: 1)
        let a = SunburstLayout.path(for: segs[0], geometry: g)
        let b = SunburstLayout.path(for: segs[1], geometry: g)
        let inA = g.point(fraction: 0.3, radius: g.inner + g.ring / 2)
        let inB = g.point(fraction: 0.85, radius: g.inner + g.ring / 2)
        #expect(a.contains(inA) && !a.contains(inB))
        #expect(b.contains(inB) && !b.contains(inA))
        #expect(!a.contains(g.center))   // the center disc isn't part of a ring
    }

    // MARK: Memory safety

    @Test func segmentsDoNotKeepTheTreeAlive() {
        var segs: [SunburstSegment] = []
        do {
            let root = makeTree(rootName: "/r", ["a/x:30", "a/y:20", "b:25"] + (0..<40).map { "t\($0):0" })
            segs = SunburstLayout.make(center: root, size: disk, hidden: 10)
            #expect(segs.allSatisfy { $0.parent != nil })
            #expect(segs.filter { $0.kind == .item }.allSatisfy { $0.node != nil })
        }
        #expect(!segs.isEmpty)
        #expect(segs.allSatisfy { $0.node == nil && $0.parent == nil })
    }

    @Test func detachedSubtreeIsReleased() {
        let root = makeTree(rootName: "/r", ["a/x:30", "b:25"])
        let segs = SunburstLayout.make(center: root, size: disk)
        let a = root["a"]!
        root.remove(a)
        #expect(segs.first { $0.name == "a" }?.node === a)   // still held by the local `a`
        _ = a
        let segs2 = SunburstLayout.make(center: root, size: disk)
        #expect(segs2.map(\.name) == ["b"])
    }

    // MARK: Palette

    @Test func paletteDistinguishesKinds() {
        let root = makeTree(rootName: "/r", ["d/f:10", "g:5"])
        let segs = SunburstLayout.make(center: root, size: disk, hidden: 5)
        for dark in [false, true] {
            let colors = segs.map { SunburstPalette.color(for: $0, dark: dark) }
            #expect(Set(colors.map { "\($0)" }).count == colors.count)   // every slice drawn differently
            for s in segs {
                #expect(SunburstPalette.color(for: s, dark: dark, highlighted: true) != SunburstPalette.color(for: s, dark: dark))
            }
        }
    }
}
