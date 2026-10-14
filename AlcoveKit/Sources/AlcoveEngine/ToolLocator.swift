import Foundation

/// Finds the helper programs that ship beside the engine.
public enum ToolLocator {
    /// The path of `alcove-proxy`: the file `$ALCOVE_PROXY` names when the variable is set, otherwise the first of
    /// `alcove-proxy` next to the running executable and `<repo>/build/alcove-proxy` that is an executable file.
    /// Nil when that file is missing or not executable.
    public static func proxy(environment: [String: String] = ProcessInfo.processInfo.environment,
                             executableDirectory: String? = directory(ofExecutable: Bundle.main.executableURL),
                             developmentRoot: String = developmentBuildDirectory,
                             fileManager fm: FileManager = .default) -> String? {
        if let named = environment["ALCOVE_PROXY"], !named.isEmpty {
            return isProgram(named, fm) ? named : nil
        }
        var candidates: [String] = []
        if let executableDirectory { candidates.append(executableDirectory + "/alcove-proxy") }
        candidates.append(developmentRoot + "/alcove-proxy")
        return candidates.first { isProgram($0, fm) }
    }

    /// The folder of the file `executable` is or, when it is a symbolic link, leads to.
    public static func directory(ofExecutable executable: URL?) -> String? {
        executable?.resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    /// `<repo>/build`, derived from this source file's location.
    public static var developmentBuildDirectory: String {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("build").path
    }

    private static func isProgram(_ path: String, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && fm.isExecutableFile(atPath: path)
    }
}
