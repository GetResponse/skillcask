import Foundation

/// What live refresh watches for one scope: the files and directories its documents are read from, and the
/// directories an FSEvents stream covers to see them change. Pure apart from resolving symlinks, so the filter is
/// tested without a stream.
///
/// The locations are the manifest, the lock and `config.toml` (policy and targets), the store (`.agents/skills`), a
/// project's skills (`status`'s `targets.local`, `.skills` from a CLI that does not print it) and every agent target
/// directory `status` reported. A change under one of them, or to a directory between it and the scope's root
/// (`.agents` created or removed), is relevant; anything else in the project (sources, `node_modules`, `.git`) is
/// not. Paths are canonical, symlinks resolved, as FSEvents reports them (`/private/var/…` for `/var/…`); a location
/// whose last component is a symlink (`.claude/skills -> elsewhere`) is also kept under its own name, so retargeting
/// the link is relevant where its parent is watched (inside a project; not `~/.claude` for the personal scope).
///
/// A location that does not exist is watched through its nearest existing directory only inside the project root
/// (which exists) or the config directory: a missing target or store elsewhere (`~/.claude/skills`, `~/.agents/skills`)
/// is not watched until a refresh finds it (the plan is rebuilt from every snapshot), rather than watching the busy
/// folder above it. The home folder and everything above it are never roots, so a project whose folder is the home
/// directory has none of its own files watched, and a deleted project never makes its parent one.
public struct WatchPlan: Hashable, Sendable {
    /// The store, relative to the scope's root (`STORE` in `src/project.rs`).
    public static let store = ".agents/skills"
    /// A project's own skills, by default (`local` in `skills.toml`); used when `status` does not report `local`.
    public static let projectSkills = ".skills"

    /// Canonical paths of what the scope's documents are read from, and the own names of those that are symlinks.
    public let locations: [String]
    /// Canonical paths of the directories to watch, sorted, none inside another.
    public let roots: [String]
    /// Heavy directories directly under a watched project root (`heavyDirectories` that exist and hold no
    /// location), left out of the stream so build and VCS churn never reaches the filter or forces a rescan.
    public let exclusions: [String]
    /// What `exclusions` is drawn from; eight, FSEvents' limit (`FSEventStreamSetExclusionPaths`). Churn in other
    /// folders (`.venv`, `Pods`, `coverage`) reaches the filter, which drops it, rescans included (`accepts`).
    public static let heavyDirectories = [
        ".git", "node_modules", "target", ".build", "build", "dist", "vendor", "DerivedData",
    ]
    /// Canonical paths at which a change says nothing about the skills: the scope's root, the config directory and
    /// everything above them (a file added to the project root changes the root itself).
    let boundaries: Set<String>

    /// - Parameters:
    ///   - configDirectory: The CLI's config directory (`Scope.configDirectory`), home of `config.toml` and of the
    ///     personal manifest.
    ///   - targetDirs: `status`'s `targets.dirs`, relative to the scope's root or absolute.
    ///   - local: `status`'s `targets.local`, the project skills directory relative to the project root; nil (an
    ///     older CLI, or the personal scope) means `.skills` for a project.
    ///   - home: The home directory, the personal scope's root; it is never watched as a whole.
    public init(
        scope: Scope, configDirectory: URL, targetDirs: [String], local: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let root = scope.isPersonal ? home : scope.root
        let manifestDirectory = scope.isPersonal ? configDirectory : root
        var urls = [
            manifestDirectory.appending(path: "skills.toml"), manifestDirectory.appending(path: "skills.lock"),
            configDirectory.appending(path: "config.toml"), root.appending(path: Self.store),
        ]
        if !scope.isPersonal {
            let local = local.flatMap { $0.isEmpty ? nil : $0 } ?? Self.projectSkills
            urls.append(root.appending(path: local))
        }
        // `appending(path:)`, not `URL(fileURLWithPath:relativeTo:)`: a base without a trailing slash would lose
        // its last component (`app/.claude/skills` resolving to `work/.claude/skills`).
        urls += targetDirs.map { dir in
            if dir.hasPrefix("/") {
                URL(fileURLWithPath: dir)
            } else if dir.hasPrefix("~/") {
                home.appending(path: String(dir.dropFirst(2)))
            } else {
                root.appending(path: dir)
            }
        }
        let paths = urls.map(\.standardizedFileURL.path)
        let canonicals = Array(Set(paths.map(Self.canonical))).sorted()
        // The link itself, when the last component is one: its parent resolved, its name kept.
        let ownNames = paths.compactMap { path -> String? in
            let parent = Self.canonical((path as NSString).deletingLastPathComponent)
            let named = (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            return canonicals.contains(named) ? nil : named
        }
        let locations = Array(Set(canonicals + ownNames)).sorted()
        let home = Self.canonical(home.standardizedFileURL.path)
        let rootPath = Self.canonical(root.standardizedFileURL.path)
        let configPath = Self.canonical(configDirectory.standardizedFileURL.path)
        let stops = [rootPath, configPath, home]
        var boundaries: Set<String> = ["/"]
        for stop in stops {
            var path = stop
            while path != "/" {
                boundaries.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        self.locations = locations
        self.boundaries = boundaries
        // Where a missing location may be watched from: the project root (it exists; never the personal scope's
        // home) and the config directory. Climbing out of them would watch `~/.claude`, `~/.config` or, for a
        // deleted project, its parent (the whole `~/work`).
        let anchors = [scope.isPersonal || !Self.isDirectory(rootPath) ? nil : rootPath, configPath].compactMap { $0 }
        let candidates = canonicals.compactMap { location -> String? in
            var path = location
            while path != "/", !Self.isDirectory(path) {
                path = (path as NSString).deletingLastPathComponent
            }
            if path == "/" || path == home || Self.isInside(path, home) {
                return nil
            }
            return path == location || anchors.contains { path == $0 || Self.isInside($0, path) } ? path : nil
        }
        let roots = Self.outermost(candidates)
        self.roots = roots
        exclusions =
            scope.isPersonal || !roots.contains(rootPath)
            ? []
            : Self.heavyDirectories.map { (rootPath as NSString).appendingPathComponent($0) }
                .filter { dir in
                    Self.isDirectory(dir)
                        && !locations.contains { $0 == dir || Self.isInside(dir, $0) || Self.isInside($0, dir) }
                }
    }

    /// Whether a directory (not a symlink to one: paths here are canonical) is at `path`.
    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether a change FSEvents reported at `path` can change what the scope shows. An empty path (the
    /// `HistoryDone` sentinel's) never is.
    public func isRelevant(_ path: String) -> Bool {
        let path = Self.trimmed(path)
        guard !path.isEmpty else { return false }
        return locations.contains { location in
            path == location || Self.isInside(location, path)
                || (Self.isInside(path, location) && !boundaries.contains(path))
        }
    }

    /// Whether one reported event is delivered: a change at a relevant path, or a rescan (`MustScanSubDirs`, dropped
    /// events, a changed root) whose directory is relevant or holds a location (the project root, `/`). A rescan of
    /// `.venv/lib` or `Pods` after build churn is dropped; one with no path at all could be anywhere and delivers.
    public func accepts(_ path: String, rescan: Bool) -> Bool {
        guard rescan else { return isRelevant(path) }
        let path = Self.trimmed(path)
        return path.isEmpty || isRelevant(path) || locations.contains { Self.isInside(path, $0) }
    }

    /// `path` without a trailing `/` (FSEvents reports some directories with one).
    private static func trimmed(_ path: String) -> String {
        path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
    }

    /// Whether `path` lies strictly inside `directory`; never for an empty path or directory.
    static func isInside(_ directory: String, _ path: String) -> Bool {
        guard !directory.isEmpty, !path.isEmpty else { return false }
        return path.hasPrefix(directory == "/" ? "/" : directory + "/") && path != directory
    }

    /// The paths of `paths` not inside another, sorted and unique.
    static func outermost(_ paths: [String]) -> [String] {
        let unique = Set(paths)
        return unique.filter { path in !unique.contains { isInside($0, path) } }.sorted()
    }

    /// `path` with the symlinks of its longest existing prefix resolved (`realpath(3)`); the missing rest is
    /// appended as given.
    static func canonical(_ path: String) -> String {
        var head = path
        var tail: [String] = []
        while head != "/" {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return tail.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) }
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return tail.reversed().reduce("/") { ($0 as NSString).appendingPathComponent($1) }
    }
}
