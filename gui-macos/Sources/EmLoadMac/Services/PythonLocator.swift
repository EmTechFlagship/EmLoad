import Foundation

/// Where to find the Python engine and the directory to run it from.
struct PythonLocation {
    let python: String
    let root: String
}

/// Finds a Python interpreter that can run `python -m EmLoadEngine rpc`.
///
/// Resolution order:
/// 1. `EMLOAD_PYTHON` (full path to an interpreter)
/// 2. `EMLOAD_ROOT` + a venv inside it
/// 3. The repo checkout that contains this app (walking up from the bundle)
/// 4. The engine copied into `EmLoad.app/Contents/Resources/engine`
/// 5. A few common checkout locations
/// 6. `python3` on PATH (last resort; may lack the engine's dependencies)
enum PythonLocator {
    static func locate() -> PythonLocation {
        let environment = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        if let explicit = environment["EMLOAD_PYTHON"], fm.isExecutableFile(atPath: explicit) {
            let root = findRoot() ?? bundledEngineRoot()
                ?? (explicit as NSString).deletingLastPathComponent
            return PythonLocation(python: explicit, root: importRoot(for: root))
        }

        var roots: [String] = []
        if let explicitRoot = environment["EMLOAD_ROOT"], fm.fileExists(atPath: explicitRoot) {
            roots.append(explicitRoot)
        }
        if let root = findRoot() { roots.append(root) }
        if let root = bundledEngineRoot() { roots.append(root) }
        roots.append(contentsOf: commonRoots())
        if let root = findRoot() { roots.append(root) }

        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            if let python = venvPython(in: "\(root)/EmLoadEngine") ?? venvPython(in: root) {
                return PythonLocation(python: python, root: importRoot(for: root))
            }
        }

        // A bundled engine without a venv can still run if the user installed
        // requirements into their system/Homebrew Python.
        let root = bundledEngineRoot() ?? findRoot() ?? fm.currentDirectoryPath
        return PythonLocation(python: findPythonOnPath(), root: importRoot(for: root))
    }

    // MARK: - Roots

    private static func commonRoots() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/EmLoadEngine",
            "\(home)/Developer/EmLoadEngine",
            "\(home)/Documents/EmLoadEngine",
            "\(home)/src/EmLoadEngine",
            "\(home)/Projects/EmLoadEngine",
            "\(home)/EmLoadServer",
            "\(home)/Developer/EmLoadServer",
            "\(home)/Documents/EmLoadServer",
            "\(home)/src/EmLoadServer",
            "\(home)/Projects/EmLoadServer",
            "/opt/emload",
        ]
    }

    /// Walk up from the app bundle and the current directory looking for a
    /// checkout (an `EmLoadEngine` or `emload` package).
    private static func findRoot() -> String? {
        var starts: [URL] = []
        if let bundle = Bundle.main.bundleURL as URL? {
            starts.append(bundle)
        }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for start in starts {
            var directory = start
            for _ in 0..<10 {
                if isCheckout(directory) { return directory.path }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    /// zsign compiled into the app by `scripts/build-app.sh`.
    ///
    /// Used when the engine is the checkout (which has no Mach-O in `vendor/`)
    /// rather than the copy inside the bundle.
    static func bundledZsign() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("zsign").path)
            candidates.append(resources.appendingPathComponent("engine/EmLoadEngine/vendor/zsign").path)
            candidates.append(resources.appendingPathComponent("engine/emload/vendor/zsign").path)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zsign").path)
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The engine copied by `scripts/build-app.sh`.
    private static func bundledEngineRoot() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let engine = resources.appendingPathComponent("engine")
        if isCheckout(engine) { return engine.path }

        // Fall back to the recorded checkout (development builds).
        let marker = resources.appendingPathComponent("engine-root.txt")
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            let root = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !root.isEmpty, isCheckout(URL(fileURLWithPath: root)) { return root }
        }
        return nil
    }

    private static func isCheckout(_ directory: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("EmLoadEngine/__init__.py").path) {
            return true
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("emload/__init__.py").path) {
            return true
        }
        // A clone of the engine repo: the package files sit in the repo root,
        // and the folder itself is named EmLoadEngine.
        return directory.lastPathComponent == "EmLoadEngine"
            && fm.fileExists(atPath: directory.appendingPathComponent("__init__.py").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("cli.py").path)
    }

    /// Directory `python -m EmLoadEngine` must be started in.
    ///
    /// A cloned engine repo is the package itself, so the process has to run
    /// from its parent. A checkout that already contains an `EmLoadEngine/`
    /// folder is started in place.
    private static func importRoot(for checkout: String) -> String {
        let directory = URL(fileURLWithPath: checkout)
        let fm = FileManager.default
        let flat = directory.lastPathComponent == "EmLoadEngine"
            && fm.fileExists(atPath: directory.appendingPathComponent("__init__.py").path)
            && !fm.fileExists(atPath: directory.appendingPathComponent("EmLoadEngine/__init__.py").path)
        if flat {
            return directory.deletingLastPathComponent().path
        }
        return checkout
    }

    // MARK: - Interpreter

    private static func venvPython(in root: String) -> String? {
        let fm = FileManager.default
        let candidates = [
            "\(root)/.venv/bin/python3",
            "\(root)/.venv/bin/python",
            "\(root)/venv/bin/python3",
            "\(root)/venv/bin/python",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func findPythonOnPath() -> String {
        let fm = FileManager.default
        let fixed = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        if let found = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            for name in ["python3", "python"] {
                let candidate = "\(directory)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return "/usr/bin/python3"
    }
}
