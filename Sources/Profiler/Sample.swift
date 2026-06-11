import Foundation

// Parsing and classification of the macOS `sample` tool's top-of-stack report.

/// One symbol from the sample's "Sort by top of stack" section.
struct SampleRow {
  let symbol: String
  let image: String
  let count: Int
}

/// Top-level bucket: our emulator code, or Swift's runtime machinery.
enum Bucket {
  case emulator
  case runtime
}

/// Sub-bucket within the Swift runtime, the categories that dominate `-Onone`.
enum Runtime: CaseIterable {
  case exclusivity
  case pltStubs
  case arc
  case typeMetadata
  case other

  var label: String {
    switch self {
    case .exclusivity: return "exclusivity"
    case .pltStubs: return "PLT stubs"
    case .arc: return "ARC"
    case .typeMetadata: return "type metadata"
    case .other: return "other"
    }
  }
}

/// Pull the symbol/image/count triples out of `sample`'s top-of-stack section.
func parseTopOfStack(_ text: String) -> [SampleRow] {
  // e.g. "        PPU.renderPixel()  (in Profiler)        133"
  guard let regex = try? Regex(#"^\s+(.+?)\s+\(in\s+([^)]+)\)\s+(\d+)\s*$"#)
  else { return [] }

  var rows: [SampleRow] = []
  var started = false
  for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    if !started {
      if line.contains("Sort by top of stack") { started = true }
      continue
    }

    guard let match = try? regex.firstMatch(in: String(line)),
      let symbol = match.output[1].substring,
      let image = match.output[2].substring,
      let countText = match.output[3].substring,
      let count = Int(countText)
    else {
      if rows.isEmpty {
        continue
      }  // skip header/blank lines after the marker

      break  // first gap after real rows ends the section
    }

    rows.append(
      SampleRow(
        symbol: String(symbol),
        image: String(image),
        count: count,
      ),
    )
  }
  return rows
}

/// `sample` reports its interval as "... every 1 millisecond".
func parseIntervalMS(_ text: String) -> Int {
  guard let regex = try? Regex(#"every (\d+) milli"#),
    let match = try? regex.firstMatch(in: text),
    let s = match.output[1].substring,
    let n = Int(s)
  else {
    return 1
  }

  return n
}

/// A `DYLD-STUB$$` symbol is a PLT (procedure linkage table) stub, regardless
/// of what it ultimately calls.
private func isStub(_ s: String) -> Bool {
  s.hasPrefix("DYLD-STUB$$")
}

/// True for anything that is Swift runtime / standard-library machinery rather
/// than our own code.
private func isRuntimeSymbol(_ s: String) -> Bool {
  if isStub(s) || s.hasPrefix("swift_") || s.hasPrefix("__swift") {
    return true
  }

  if s.contains("swift::runtime::") {
    return true
  }

  let phrases = [
    "protocol witness", "witness table", "type metadata", "value witness",
    "metadata accessor", "RangeExpression", "ClosedRange", "Array.subscript",
    "Comparable.", "_finalize", "deduplicated_symbol",
  ]

  return phrases.contains { s.contains($0) }
}

func bucket(_ row: SampleRow) -> Bucket {
  let inMainBinary = (row.image == "Profiler")

  return
    (inMainBinary && !isRuntimeSymbol(row.symbol))
    ? .emulator
    : .runtime
}

func runtimeKind(_ symbol: String) -> Runtime {
  if isStub(symbol) {
    return .pltStubs
  }

  func matchesAny(_ needles: [String]) -> Bool {
    needles.contains { symbol.contains($0) }
  }

  if matchesAny([
    "beginAccess", "endAccess", "AccessSet", "SwiftTLSContext", "Exclusiv",
  ]) {
    return .exclusivity
  }

  if matchesAny([
    "retain", "Retain", "release", "Release", "isUniquelyReferenced",
    "unowned", "Unowned", "bridgeObject",
  ]) {
    return .arc
  }

  if matchesAny([
    "getObjectType", "instantiateConcreteType", "TypeByMangledName",
    "metadata", "witness", "getType",
  ]) {
    return .typeMetadata
  }

  return .other
}
