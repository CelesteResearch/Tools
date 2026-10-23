using System.Security.Cryptography;

namespace Celeste.Tools.ModSourceConverter;

internal static class LockedPaths
{
    internal static StringComparer Comparer => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    internal static string Root(string value, bool mustExist)
    {
        string full = Path.GetFullPath(value);
        if (Path.GetPathRoot(full) == full || (mustExist && !Directory.Exists(full)))
            throw new ConversionException("Invalid root directory.");
        RejectLinks(full);
        return Path.TrimEndingDirectorySeparator(full);
    }

    internal static string Relative(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Contains('\\') || value.Contains(':') ||
            Path.IsPathRooted(value) || value.Split('/').Any(part => part is "" or "." or ".."))
            throw new ConversionException("Invalid locked relative path.");
        return value;
    }

    internal static string Resolve(string root, string relative)
    {
        Relative(relative);
        string full = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!Within(root, full)) throw new ConversionException("Path leaves the declared root.");
        RejectLinks(full);
        return full;
    }

    internal static bool Within(string root, string path) => path.StartsWith(
        Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar,
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    internal static void RejectLinks(string full)
    {
        for (string? current = full; current != null; current = Path.GetDirectoryName(current))
        {
            FileSystemInfo item = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            if (item.LinkTarget != null || (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0))
                throw new ConversionException("Linked input/output paths are not permitted.");
        }
    }

    internal static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    internal static void RequireHash(string value)
    {
        if (value.Length != 64 || value.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
            throw new ConversionException("A lowercase SHA-256 lock is required.");
    }

    internal static void Commit(string outputRoot, IReadOnlyDictionary<string, byte[]> outputs)
    {
        if (Directory.Exists(outputRoot))
        {
            var existing = new List<string>();

            void Scan(string directory)
            {
                RejectLinks(directory);
                foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
                {
                    RejectLinks(entry);
                    if (Directory.Exists(entry)) Scan(entry);
                    else existing.Add(Path.GetRelativePath(outputRoot, entry).Replace('\\', '/'));
                }
            }

            Scan(outputRoot);
            if (existing.Count != 0)
            {
                if (existing.Count != outputs.Count || existing.Any(path => !outputs.ContainsKey(path) ||
                                                                            !File.ReadAllBytes(
                                                                                    Resolve(outputRoot, path)).AsSpan()
                                                                                .SequenceEqual(outputs[path])))
                    throw new ConversionException("Existing output directory does not match the complete lock.");
                return;
            }

            // A genuinely empty directory is the only pre-existing directory that can be replaced.
            if (Directory.EnumerateFileSystemEntries(outputRoot).Any())
                throw new ConversionException("Output directory contains unlisted directories.");
        }
        else if (File.Exists(outputRoot)) throw new ConversionException("Output root is not a directory.");

        string parent = Path.GetDirectoryName(outputRoot)!;
        RejectLinks(parent);
        Directory.CreateDirectory(parent);
        string staging = Path.GetFullPath(Path.Combine(parent, ".mod-converter-" + Guid.NewGuid().ToString("N")));
        if (!Within(parent, staging)) throw new ConversionException("Invalid private staging location.");
        Directory.CreateDirectory(staging);
        try
        {
            foreach ((string relative, byte[] bytes) in outputs)
            {
                string target = Resolve(staging, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.WriteAllBytes(target, bytes);
            }

            RejectLinks(outputRoot);
            if (Directory.Exists(outputRoot)) Directory.Delete(outputRoot, false);
            try
            {
                Directory.Move(staging, outputRoot);
            }
            catch (IOException error)
            {
                error.Data["ConverterOutputRoot"] = outputRoot;
                throw;
            }
        }
        finally
        {
            if (Directory.Exists(staging))
            {
                RejectLinks(staging);
                if (!Within(parent, staging)) throw new ConversionException("Invalid private staging cleanup.");
                Directory.Delete(staging, true);
            }
        }
    }
}
