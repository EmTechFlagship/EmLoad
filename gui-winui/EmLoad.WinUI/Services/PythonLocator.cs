namespace EmLoad.WinUI.Services;

/// <summary>
/// Finds the repo's virtual environment so the WinUI shell can start
/// <c>python -m emload rpc</c> without the app being installed.
///
/// Resolution order:
/// 1. <c>EMLOAD_PYTHON</c> (full path to a python.exe)
/// 2. <c>EMLOAD_ROOT</c> + <c>.venv\Scripts\python.exe</c>
/// 3. Walk up from the executable looking for <c>pyproject.toml</c>
/// 4. <c>python</c> on PATH (last resort; may lack the engine's dependencies)
/// </summary>
public static class PythonLocator
{
    public static (string Python, string Root) Locate()
    {
        var explicitPython = Environment.GetEnvironmentVariable("EMLOAD_PYTHON");
        if (!string.IsNullOrWhiteSpace(explicitPython) && File.Exists(explicitPython))
        {
            return (explicitPython, FindRoot() ?? Path.GetDirectoryName(explicitPython)!);
        }

        var explicitRoot = Environment.GetEnvironmentVariable("EMLOAD_ROOT");
        if (!string.IsNullOrWhiteSpace(explicitRoot) && Directory.Exists(explicitRoot))
        {
            return (VenvPython(explicitRoot) ?? "python", explicitRoot);
        }

        var root = FindRoot();
        if (root is not null)
        {
            var venv = VenvPython(root);
            if (venv is not null)
            {
                return (venv, root);
            }
        }

        return ("python", root ?? Directory.GetCurrentDirectory());
    }

    private static string? VenvPython(string root)
    {
        var candidate = Path.Combine(root, ".venv", "Scripts", "python.exe");
        return File.Exists(candidate) ? candidate : null;
    }

    private static string? FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; depth < 10 && directory is not null; depth++)
        {
            if (File.Exists(Path.Combine(directory.FullName, "pyproject.toml")) &&
                Directory.Exists(Path.Combine(directory.FullName, "emload")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }

        // A published build may sit outside the repo; fall back to the current
        // directory so `dotnet run` from the repo still works.
        var cwd = Directory.GetCurrentDirectory();
        return File.Exists(Path.Combine(cwd, "pyproject.toml")) ? cwd : null;
    }
}
