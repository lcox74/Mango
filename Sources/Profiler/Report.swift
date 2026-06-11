import Foundation

extension Sequence {
    /// Sum an integer projection of the elements.
    func sum(of f: (Element) -> Int) -> Int { reduce(0) { $0 + f($1) } }
}

/// Everything we know about one profiled scene.
private struct SceneProfile {
    let stats: SceneStats
    let intervalMS: Int
    let rows: [SampleRow]

    let total: Int
    let counts: [String: Int]  // raw symbol to samples
    let emu: Int
    let sub: [Runtime: Int]

    init(stats: SceneStats, intervalMS: Int, rows: [SampleRow]) {
        self.stats = stats
        self.intervalMS = intervalMS
        self.rows = rows

        var counts: [String: Int] = [:]
        var emu = 0
        var sub: [Runtime: Int] = [:]

        for row in rows {
            counts[row.symbol, default: 0] += row.count

            if bucket(row) == .emulator {
                emu += row.count
            } else {
                sub[runtimeKind(row.symbol), default: 0] += row.count
            }
        }

        self.counts = counts
        self.total = rows.sum(of: \.count)
        self.emu = emu
        self.sub = sub
    }

    /// Wall-clock seconds the sampler was attached (samples * interval).
    var sampledSeconds: Double { Double(total * intervalMS) / 1000.0 }

    /// Frames emulated during the sample window, derived from the measured rate.
    var frames: Int {
        stats.msPerFrame > 0
            ? Int((sampledSeconds * 1000.0 / stats.msPerFrame).rounded())
            : 0
    }

    var budgetPct: Double { stats.msPerFrame / stats.budgetMS * 100.0 }

    func share(_ symbol: String) -> Double {
        total > 0
            ? Double(counts[symbol] ?? 0) / Double(total) * 100.0
            : 0
    }
}

/// `-Onone` keeps the runtime safety machinery as real calls; `-O` elides it.
/// SwiftPM defines `DEBUG` for the debug build configuration.
private var buildConfig: String {
    #if DEBUG
        return "debug"
    #else
        return "release"
    #endif
}

func runReport(sampleFiles: [String]) {
    // With no files given, fall back to the standard per-scene files in /tmp.
    var files = sampleFiles
    if files.isEmpty {
        files = Scene.all
            .map { "/tmp/mango-sample-\($0.name).txt" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    var scenes: [SceneProfile] = []
    for file in files {

        guard let text = try? String(contentsOfFile: file, encoding: .utf8)
        else {
            logErr("report: could not read \(file)")
            continue
        }

        let rows = parseTopOfStack(text)
        guard !rows.isEmpty
        else {
            logErr("report: no 'Sort by top of stack' data in \(file)")
            continue
        }

        guard let stats = SceneStats.read(from: defaultStatsPath(forSample: file))
        else {
            logErr("report: no timing sidecar for \(file)")
            continue
        }

        scenes.append(
            SceneProfile(
                stats: stats,
                intervalMS: parseIntervalMS(text),
                rows: rows,
            ),
        )
    }

    guard !scenes.isEmpty else {
        logErr("report: no usable scenes")
        exit(1)
    }

    scenes.sort { $0.stats.startFrame < $1.stats.startFrame }

    render(scenes: scenes)
}

// ASCII category markers
private let markerEmulator = "="
private let markerRuntime = "-"

private func render(scenes: [SceneProfile]) {

    // Pool every scene's samples for the overall split and ranking.
    let pooledCount = Dictionary(
        scenes.flatMap { $0.rows }.map { ($0.symbol, $0.count) },
        uniquingKeysWith: +
    )

    var repRow: [String: SampleRow] = [:]
    for row in scenes.flatMap({ $0.rows }) where repRow[row.symbol] == nil {
        repRow[row.symbol] = row
    }

    let total = scenes.sum(of: \.total)
    let emu = scenes.sum(of: \.emu)
    let runtime = total - emu
    var sub: [Runtime: Int] = [:]
    for s in scenes { sub.merge(s.sub, uniquingKeysWith: +) }

    let totalFrames = scenes.sum(of: \.frames)
    let totalTimeMS = scenes.reduce(0.0) { $0 + Double($1.frames) * $1.stats.msPerFrame }
    let avgMS = totalFrames > 0 ? totalTimeMS / Double(totalFrames) : 0
    let budgetMS = scenes.first?.stats.budgetMS ?? (1000.0 / 60.0)
    let intervalMS = scenes.first?.intervalMS ?? 1

    // Header.
    let n = scenes.count
    print("")
    print(
        "  "
            + ANSI.bold("Profiler")
            + ANSI.dim(" | mango | \(buildConfig) | \(n) scene\(n == 1 ? "" : "s")")
    )
    print(
        "  "
            + ANSI.bold(grouped(total)) + " samples " + ANSI.dim("@ \(intervalMS) ms")
            + ANSI.dim(" | ")
            + ANSI.bold(grouped(totalFrames)) + ANSI.dim(" frames | ")
            + ANSI.bold(String(format: "%.2f", avgMS)) + ANSI.dim(" ms/frame avg")
    )

    // Scenes table.
    print("")
    print("  " + ANSI.bold("Scenes"))
    print(
        "  "
            + ANSI.dim(
                padRight("scene", 11) + padRight("steps", 13) + padLeft("frames", 7)
                    + padLeft("ms/frame", 10) + padLeft("budget", 8) + padLeft("emu", 8)
                    + padLeft("swift", 8)
            )
    )

    for s in scenes {
        let emuPct =
            s.total > 0
            ? Double(s.emu) / Double(s.total) * 100.0
            : 0

        print(
            "  " + padRight(s.stats.name, 11)
                + padRight("\(s.stats.startFrame)-\(s.stats.endFrame)", 13)
                + padLeft(grouped(s.frames), 7)
                + padLeft(String(format: "%.2f", s.stats.msPerFrame), 10)
                + padLeft(pct(s.budgetPct), 8)
                + padLeft(pct(emuPct), 8)
                + padLeft(pct(100 - emuPct), 8)
        )
    }

    if n > 1 {
        let emuPct =
            total > 0
            ? Double(emu) / Double(total) * 100.0
            : 0

        print(
            "  "
                + ANSI.bold(padRight("all", 11)) + padRight("", 13)
                + ANSI.bold(padLeft(grouped(totalFrames), 7))
                + ANSI.bold(padLeft(String(format: "%.2f", avgMS), 10))
                + ANSI.bold(padLeft(pct(avgMS / budgetMS * 100.0), 8))
                + ANSI.bold(padLeft(pct(emuPct), 8))
                + ANSI.bold(padLeft(pct(100 - emuPct), 8))
        )
    }

    // Pooled CPU split.
    print("")
    print("  " + ANSI.bold("CPU split") + ANSI.dim("  (pooled)"))
    splitLine(
        marker: markerEmulator,
        color: cyan,
        name: "emulator",
        count: emu,
        total: total,
    )
    splitLine(
        marker: markerRuntime,
        color: yellow,
        name: "swift runtime",
        count: runtime,
        total: total,
    )

    for kind in Runtime.allCases {
        let c = sub[kind] ?? 0
        if c == 0 {
            continue
        }

        subLine(name: kind.label, count: c, total: total)
    }

    // Hottest functions, pooled ranking with a per-scene breakdown.
    let nameWidth = 24
    print("")
    print("  " + ANSI.bold("Hottest functions") + ANSI.dim("  (samp%)"))
    var columns =
        padLeft("#", 3)
        + "  "
        + padRight("symbol", nameWidth + 2)
        + "  " + padLeft("all", 6)

    if n > 1 {
        for s in scenes {
            columns += padLeft(abbrev(s.stats.name), 7)
        }
    }

    print("  " + ANSI.dim(columns))

    let ranked = pooledCount.sorted { $0.value > $1.value }.prefix(12)

    for (i, entry) in ranked.enumerated() {
        let symbol = entry.key

        guard let rep = repRow[symbol]
        else { continue }

        let isEmu = bucket(rep) == .emulator
        let color = isEmu ? cyan : yellow
        let marker = isEmu ? markerEmulator : markerRuntime
        let name = color(marker + " " + padRight(prettify(symbol), nameWidth))

        var line = ANSI.dim(padLeft("\(i + 1)", 3)) + "  " + name + "  "

        line += ANSI.bold(
            padLeft(String(format: "%.1f", Double(entry.value) / Double(total) * 100.0), 6)
        )

        if n > 1 {
            for s in scenes {
                line += ANSI.dim(padLeft(String(format: "%.1f", s.share(symbol)), 7))
            }
        }

        print("  " + line)
    }
    print("")
}

private func cyan(_ s: String) -> String { ANSI.cyan(s) }
private func yellow(_ s: String) -> String { ANSI.yellow(s) }

/// A `= emulator   40.1%  [====    ]  3,414` line for the pooled CPU split.
private func splitLine(
    marker: String, color: (String) -> String, name: String, count: Int, total: Int
) {
    let share =
        total > 0
        ? Double(count) / Double(total) * 100.0
        : 0

    print(
        "  "
            + color(marker) + " " + color(padRight(name, 14)) + " " + padLeft(pct(share), 5) + "  "
            + color(bar(count, max: total, width: 20)) + "  "
            + ANSI.bold(padLeft(grouped(count), 6))
    )
}

/// An indented runtime sub-category line.
private func subLine(name: String, count: Int, total: Int) {
    let share =
        total > 0
        ? Double(count) / Double(total) * 100.0
        : 0

    print(
        "      "
            + ANSI.dim(padRight(name, 14)) + " " + padLeft(pct(share), 5) + "  "
            + ANSI.dim(bar(count, max: total, width: 20)) + "  "
            + ANSI.bold(padLeft(grouped(count), 6))
    )
}

private func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

private func abbrev(_ name: String) -> String {
    name == "autoplay" ? "auto" : name
}

/// Tidy a raw `sample` symbol for display.
private func prettify(_ symbol: String) -> String {
    var s = symbol
    if s.hasPrefix("DYLD-STUB$$") {
        s = "stub " + s.dropFirst("DYLD-STUB$$".count)
    }

    s = s.replacingOccurrences(of: "swift::runtime::", with: "")

    if let open = s.firstIndex(of: "(") {
        let args = s[s.index(after: open)...].dropLast()  // strip the trailing ")"

        if args.contains("::") || args.contains(",") || args.contains(" ") || args.count > 12 {
            s = s[..<open] + "(...)"
        }
    }

    return s
}

/// Format an integer with thousands separators, e.g. 8523 -> "8,523".
private func grouped(_ n: Int) -> String {
    n.formatted(.number.locale(Locale(identifier: "en_US")))
}
