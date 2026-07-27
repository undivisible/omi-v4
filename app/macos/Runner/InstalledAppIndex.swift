import Cocoa

/// Cached index of installed `.app` bundles for the overlay launcher.
///
/// The previous implementation rescanned every application root on each
/// `openApp` call, which made search feel slow and could return no match while
/// a scan was still in flight. This index is warmed at launch, refreshed on a
/// short TTL, and walks one level of subdirectories so apps in folders such as
/// `/Applications/Setapp/` are discoverable.
final class InstalledAppIndex {
  static let shared = InstalledAppIndex()

  struct Entry: Equatable {
    let url: URL
    let name: String
    let normalized: String
  }

  private let lock = NSLock()
  private var entries: [Entry] = []
  private var builtAt = Date.distantPast
  private var isBuilding = false

  private let refreshInterval: TimeInterval = 300

  private init() {}

  /// Directories scanned for application bundles. Shallow roots plus one nested
  /// level (Setapp, Steam, etc.).
  static var searchRoots: [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
      URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
    ]
  }

  /// Builds the index on a background queue so the first search is fast.
  func warm() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.rebuildIfNeeded(force: true)
    }
  }

  /// Returns the best matching app URL for a query, or nil when none match.
  func resolve(query: String) -> URL? {
    let normalized = Self.normalize(query)
    guard !normalized.isEmpty else { return nil }
    rebuildIfNeeded(force: false)
    let snapshot = copyEntries()
    return Self.bestMatch(normalized: normalized, in: snapshot)?.url
  }

  /// Returns display names for apps matching `query`, best matches first.
  func search(query: String, limit: Int = 20) -> [String] {
    let normalized = Self.normalize(query)
    guard !normalized.isEmpty else { return [] }
    rebuildIfNeeded(force: false)
    let snapshot = copyEntries()
    return Self.searchEntries(normalized: normalized, in: snapshot, limit: limit)
      .map(\.name)
  }

  /// Rebuilds the index from disk. Exposed for tests.
  @discardableResult
  func rebuildForTesting() -> [Entry] {
    rebuildIfNeeded(force: true)
    return copyEntries()
  }

  /// Deterministic name match: exact name first, then prefix, then substring —
  /// all case-insensitive — so "chrome" finds "Google Chrome" and "safari"
  /// never loses to "Safari Technology Preview".
  static func resolveApplicationURL(query: String, candidates: [URL]) -> URL? {
    let normalized = normalize(query)
    guard !normalized.isEmpty else { return nil }
    let entries = candidates.map { url in
      let name = url.deletingPathExtension().lastPathComponent
      return Entry(url: url, name: name, normalized: name.lowercased())
    }
    return bestMatch(normalized: normalized, in: entries)?.url
  }

  static func installedApplicationURLs(
    roots: [URL] = searchRoots,
    maxDepth: Int = 2
  ) -> [URL] {
    var applications: [URL] = []
    var seen = Set<String>()
    for root in roots {
      collectApplications(at: root, depth: 0, maxDepth: maxDepth, into: &applications, seen: &seen)
    }
    return applications
  }

  private func copyEntries() -> [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  private func rebuildIfNeeded(force: Bool) {
    lock.lock()
    let stale = Date().timeIntervalSince(builtAt) > refreshInterval
    if !force && !entries.isEmpty && !stale {
      lock.unlock()
      return
    }
    if isBuilding {
      lock.unlock()
      return
    }
    isBuilding = true
    lock.unlock()

    let discovered = Self.discoverEntries()

    lock.lock()
    entries = discovered
    builtAt = Date()
    isBuilding = false
    lock.unlock()
  }

  private static func discoverEntries() -> [Entry] {
    var entries: [Entry] = []
    var seen = Set<String>()
    for url in installedApplicationURLs() {
      let path = url.path
      guard seen.insert(path).inserted else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      entries.append(Entry(url: url, name: name, normalized: name.lowercased()))
    }
    for app in NSWorkspace.shared.runningApplications {
      guard let url = app.bundleURL, url.pathExtension == "app" else { continue }
      let path = url.path
      guard seen.insert(path).inserted else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      entries.append(Entry(url: url, name: name, normalized: name.lowercased()))
    }
    entries.sort { $0.normalized < $1.normalized }
    return entries
  }

  private static func collectApplications(
    at root: URL,
    depth: Int,
    maxDepth: Int,
    into applications: inout [URL],
    seen: inout Set<String>
  ) {
    guard depth <= maxDepth else { return }
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return }

    for entry in entries {
      if entry.pathExtension == "app" {
        guard seen.insert(entry.path).inserted else { continue }
        applications.append(entry)
        continue
      }
      guard depth < maxDepth else { continue }
      let isDirectory =
        (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      guard isDirectory else { continue }
      collectApplications(
        at: entry, depth: depth + 1, maxDepth: maxDepth, into: &applications, seen: &seen)
    }
  }

  private static func normalize(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func bestMatch(normalized: String, in entries: [Entry]) -> Entry? {
    searchEntries(normalized: normalized, in: entries, limit: 1).first
  }

  private static func searchEntries(
    normalized: String,
    in entries: [Entry],
    limit: Int
  ) -> [Entry] {
    var exact: [Entry] = []
    var prefix: [Entry] = []
    var substring: [Entry] = []
    var scored: [(score: Int, entry: Entry)] = []
    let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    for entry in entries {
      let name = entry.normalized
      if name == normalized {
        exact.append(entry)
        continue
      }
      if name.hasPrefix(normalized) {
        prefix.append(entry)
        continue
      }
      if name.contains(normalized) {
        substring.append(entry)
        continue
      }
      if words.isEmpty { continue }
      let matchesAll = words.allSatisfy { word in
        !word.isEmpty && name.contains(word)
      }
      guard matchesAll else { continue }
      let score = words.reduce(0) { partial, word in
        partial + (name.hasPrefix(word) ? 2 : 1)
      }
      scored.append((score, entry))
    }

    var results: [Entry] = []
    var seen = Set<String>()
    for bucket in [exact, prefix.sorted { $0.normalized < $1.normalized },
                   substring.sorted { $0.normalized < $1.normalized }] {
      for entry in bucket {
        guard seen.insert(entry.url.path).inserted else { continue }
        results.append(entry)
        if results.count >= limit { return results }
      }
    }

    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.entry.normalized < rhs.entry.normalized
    }
    for (_, entry) in scored {
      guard seen.insert(entry.url.path).inserted else { continue }
      results.append(entry)
      if results.count >= limit { break }
    }
    return results
  }

  private static func rankedMatches(
    normalized: String,
    in entries: [Entry],
    limit: Int
  ) -> [Entry] {
    searchEntries(normalized: normalized, in: entries, limit: limit)
  }
}
