using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text.Json;

if (args.Length == 2 && args[0] == "--list")
{
    Console.WriteLine(JsonSerializer.Serialize(ReadResources(args[1]).Select(entry => new
    {
        name = entry.Key,
        bytes = entry.Value.Length,
        sha256 = Convert.ToHexStringLower(SHA256.HashData(entry.Value)),
    })));
    return 0;
}

if (args.Length == 4 && args[0] == "--extract")
{
    var payloads = ReadResources(args[1]);
    if (!payloads.TryGetValue(args[2], out var payload))
        throw new InvalidDataException($"Embedded resource missing: {args[2]}");
    var target = Path.GetFullPath(args[3]);
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    File.WriteAllBytes(target, payload);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        status = "pass",
        bytes = payload.Length,
        sha256 = Convert.ToHexStringLower(SHA256.HashData(payload)),
    }));
    return 0;
}

if (args.Length != 3)
{
    Console.Error.WriteLine("Usage: ResourceExtractor <celeste-directory> <repository-root> <resource-map.json>");
    return 2;
}

var gameDirectory = Path.GetFullPath(args[0]);
var repositoryRoot = Path.GetFullPath(args[1]);
var manifest = JsonSerializer.Deserialize<ResourceMap>(File.ReadAllText(args[2]),
    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
var resources = new Dictionary<string, Dictionary<string, byte[]>>(StringComparer.Ordinal);
var assemblyPaths = new Dictionary<string, string>(StringComparer.Ordinal);
foreach (var (name, candidates) in manifest.Sets)
{
    var assembly = candidates.Select(candidate => Path.Combine(gameDirectory, candidate))
                       .FirstOrDefault(File.Exists)
                   ?? throw new FileNotFoundException(
                       $"The '{name}' assembly was not found: {string.Join(", ", candidates)}");
    resources.Add(name, ReadResources(assembly));
    assemblyPaths.Add(name, assembly);
}

// Resolve and verify every payload before writing any destination.
var pending = new List<(string Target, byte[] Payload)>();
foreach (var file in manifest.Files)
{
    if (!resources[file.Set].TryGetValue(file.Resource, out var payload))
        throw new InvalidDataException($"Embedded resource missing: {file.Set}:{file.Resource}");
    var hash = Convert.ToHexStringLower(SHA256.HashData(payload));
    if (payload.LongLength != file.Bytes || hash != file.Sha256)
        throw new InvalidDataException(
            $"Installed resource version differs: {file.Set}:{file.Resource}. Expected {file.Sha256}; found {hash}.");
    var target = Inside(repositoryRoot, file.Destination);
    pending.Add((target, payload));
}

foreach (var constant in manifest.Constants ?? Array.Empty<ResourceConstant>())
{
    byte[] payload = ReadStringConstant(assemblyPaths[constant.Set], constant.Type, constant.Field);
    string hash = Convert.ToHexStringLower(SHA256.HashData(payload));
    if (payload.LongLength != constant.Bytes || hash != constant.Sha256)
        throw new InvalidDataException(
            $"Installed constant version differs: {constant.Set}:{constant.Type}.{constant.Field}. Expected {constant.Sha256}; found {hash}.");
    string target = Inside(repositoryRoot, constant.Destination);
    if (pending.Any(entry => entry.Target == target && !entry.Payload.AsSpan().SequenceEqual(payload)))
        throw new InvalidDataException($"Conflicting restored constant destination: {constant.Destination}");
    if (!pending.Any(entry => entry.Target == target)) pending.Add((target, payload));
}

var written = 0;
foreach (var (target, payload) in pending)
{
    if (File.Exists(target) && File.ReadAllBytes(target).AsSpan().SequenceEqual(payload))
        continue;
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    File.WriteAllBytes(target, payload);
    if (!File.ReadAllBytes(target).AsSpan().SequenceEqual(payload))
        throw new IOException($"Resource write verification failed: {target}");
    written++;
}

Console.WriteLine(JsonSerializer.Serialize(new
{
    status = "pass",
    resources = pending.Count,
    written,
    bytes = pending.Sum(entry => (long)entry.Payload.Length),
}));
return 0;

static string Inside(string root, string relative)
{
    if (Path.IsPathRooted(relative))
        throw new InvalidDataException($"Destination must be relative: {relative}");
    var full = Path.GetFullPath(Path.Combine(root, relative));
    var boundary = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                   + Path.DirectorySeparatorChar;
    if (!full.StartsWith(boundary,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
        throw new InvalidDataException($"Destination escapes repository: {relative}");
    return full;
}

static Dictionary<string, byte[]> ReadResources(string assemblyPath)
{
    // PEReader reads metadata and the managed-resource section. No assembly is loaded or executed.
    using var stream = File.OpenRead(assemblyPath);
    using var pe = new PEReader(stream);
    var metadata = pe.GetMetadataReader();
    var directory = pe.PEHeaders.CorHeader!.ResourcesDirectory;
    var section = pe.GetSectionData(directory.RelativeVirtualAddress);
    var result = new Dictionary<string, byte[]>(StringComparer.Ordinal);
    foreach (var handle in metadata.ManifestResources)
    {
        var entry = metadata.GetManifestResource(handle);
        if (!entry.Implementation.IsNil)
            continue;
        var offset = checked((int)entry.Offset);
        var reader = section.GetReader(offset, section.Length - offset);
        var length = reader.ReadInt32();
        if (length < 0 || length > reader.RemainingBytes)
            throw new BadImageFormatException("Invalid managed resource length.");
        result.Add(metadata.GetString(entry.Name), reader.ReadBytes(length));
    }

    return result;
}

static byte[] ReadStringConstant(string assemblyPath, string typeName, string fieldName)
{
    using var stream = File.OpenRead(assemblyPath);
    using var pe = new PEReader(stream);
    var metadata = pe.GetMetadataReader();
    foreach (var handle in metadata.TypeDefinitions)
    {
        var type = metadata.GetTypeDefinition(handle);
        string name = metadata.GetString(type.Namespace) + "." + metadata.GetString(type.Name);
        if (name != typeName) continue;
        foreach (var fieldHandle in type.GetFields())
        {
            var field = metadata.GetFieldDefinition(fieldHandle);
            if (metadata.GetString(field.Name) != fieldName) continue;
            var constantHandle = field.GetDefaultValue();
            if (constantHandle.IsNil)
                throw new InvalidDataException($"The field has no metadata constant: {typeName}.{fieldName}");
            var constant = metadata.GetConstant(constantHandle);
            if (constant.TypeCode != ConstantTypeCode.String)
                throw new InvalidDataException($"The metadata constant is not a string: {typeName}.{fieldName}");
            return metadata.GetBlobBytes(constant.Value);
        }

        throw new InvalidDataException($"Metadata constant field missing: {typeName}.{fieldName}");
    }

    throw new InvalidDataException($"Metadata constant type missing: {typeName}");
}

internal sealed record ResourceMap(
    Dictionary<string, string[]> Sets,
    ResourceFile[] Files,
    ResourceConstant[]? Constants = null);

internal sealed record ResourceFile(string Set, string Resource, string Destination, long Bytes, string Sha256);

internal sealed record ResourceConstant(
    string Set,
    string Type,
    string Field,
    string Destination,
    long Bytes,
    string Sha256);
