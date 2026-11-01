import Foundation

/// What live refresh watches for one scope: the files and directories its documents are read from, and the
/// directories an FSEvents stream covers to see them change. Pure apart from resolving symlinks, so the filter is
/// tested without a stream.
///
/// The locations are the manifest, the lock and `config.toml` (policy and targets), the store (`.agents/skills`), a
/// project's skills (`.skills`) and every agent target directory `status` reported. A change under one of them, or
/// to a directory between it and the scope's root (`.agents` created or removed), is relevant; anything else in the
/// project (sources, `node_modules`, `.git`) is not. Paths are canonical, symlinks resolved, as FSEvents reports
/// them (`/private/var/…` for `/var/…`). A project whose folder is the home directory, or no longer exists, has
/// none of its own files watched (only the config directory and targets elsewhere): the home folder is never a
/// root, and a deleted project never makes its parent one.
public struct WatchPlan: Hashable, Sendable {
    /// The store, relative to the scope's root (`STORE` in `src/project.rs`).
    public static let store = ".agents/skills"
    /// A project's own skills, by default (`local` in `skills.toml`).
    public static let projectSkills = ".skills"

    /// Canonical paths of what the scope's documents are read from.
    public let locations: [String]
    /// Canonical paths of the directories to watch, sorted, none inside another.
    public let roots: [String]
    /// Heavy directories directly under a watched project root (`heavyDirectories` that exist and hold no
    /// location), left out of the stream so build and VCS churn never reaches the filter or forces a rescan.
    public let exclusions: [String]
    /// What `exclusions` is drawn from; eight, FSEvents' limit (`FSEventStreamSetExclusionPaths`).
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
    ///   - home: The home directory, the personal scope's root; it is never watched as a whole.
    public init(
        scope: Scope, configDirectory: URL, targetDirs: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let root = scope.isPersonal ? home : scope.root
        let manifestDirectory = scope.isPersonal ? configDirectory : root
        var urls = [
            manifestDirectory.appending(path: "skills.toml"), manifestDirectory.appending(path: "skills.lock"),
            configDirectory.appending(path: "config.toml"), root.appending(path: Self.store),
        ]
        if !scope.isPersonal {
            urls.append(root.appending(path: Self.projectSkills))
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
        let locations = Array(Set(urls.map { Self.canonical($0.standardizedFileURL.path) })).sorted()
        let home = Self.canonical(home.standardizedFileURL.path)
        let stops = [Self.canonical(root.standardizedFileURL.path), Self.canonical(configDirectory.path), home]
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
        // Each location's nearest existing directory, never the home directory or above it: a missing personal
        // target is not watched until a refresh finds it (the plan is rebuilt from every snapshot), rather than
        // watching the whole home folder for it.
        // A location inside a project that is gone is not watched at all: climbing out of it would watch its
        // parent (the whole `~/work`).
        let rootPath = Self.canonical(root.standardizedFileURL.path)
        let rootExists = Self.isDirectory(rootPath)
        let candidates = locations.compactMap { location -> String? in
            if !rootExists, location == rootPath || Self.isInside(rootPath, location) {
                return nil
            }
            var path = location
            while path != "/", !Self.isDirectory(path) {
                path = (path as NSString).deletingLastPathComponent
            }
            return path == "/" || path == home || Self.isInside(path, home) ? nil : path
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

    /// Whether a change FSEvents reported at `path` can change what the scope shows.
    public func isRelevant(_ path: String) -> Bool {
        let path = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return locations.contains { location in
            path == location || Self.isInside(location, path)
                || (Self.isInside(path, location) && !boundaries.contains(path))
        }
    }

    /// Whether `path` lies strictly inside `directory`.
    static func isInside(_ directory: String, _ path: String) -> Bool {
        path.hasPrefix(directory == "/" ? "/" : directory + "/") && path != directory
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
