using System.Text.Json;
using System.Text.Json.Serialization;

namespace Celeste.Tools.ModSourceConverter;

internal sealed class Recipe
{
    public int SchemaVersion { get; set; }
    public string Newline { get; set; } = "lf";
    public List<RecipeInput> Inputs { get; set; } = [];
    public List<RecipeOutput> Outputs { get; set; } = [];
}

internal sealed class RecipeInput
{
    public string Id { get; set; } = "";
    public string Path { get; set; } = "";
    public string Sha256 { get; set; } = "";
}

internal sealed class RecipeOutput
{
    public string Path { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public List<Segment> Segments { get; set; } = [];
}

internal sealed class Segment
{
    public string? Literal { get; set; }
    public Selector? Source { get; set; }
    public SourceRange? SourceRange { get; set; }
    public int Indent { get; set; }
}

internal sealed class Selector
{
    public string Input { get; set; } = "";
    public string Type { get; set; } = "";
    public string MemberKind { get; set; } = "";
    public string? MemberName { get; set; }
    public List<string>? ParameterTypes { get; set; }
    public string Part { get; set; } = "full";
    public string Format { get; set; } = "preserve";
    public int? LambdaIndex { get; set; }
    public int? StatementStart { get; set; }
    public int? StatementCount { get; set; }
    public Mappings Maps { get; set; } = new();
}

internal sealed class Mappings
{
    public Dictionary<string, string> Tokens { get; set; } = [];
    public Dictionary<string, string> Identifiers { get; set; } = [];
    public Dictionary<string, string> Types { get; set; } = [];
    public Dictionary<string, string> MemberAccess { get; set; } = [];
    public Dictionary<string, string> Invocations { get; set; } = [];
    public List<string> RemoveArgumentNames { get; set; } = [];
    public Dictionary<string, ConstructorArguments> Constructors { get; set; } = [];
    public Dictionary<string, string> AssignmentCalls { get; set; } = [];
    public Dictionary<string, string> Expressions { get; set; } = [];
    public List<string> InitializerSuffix { get; set; } = [];
}

internal sealed class ConstructorArguments
{
    public List<string> Prefix { get; set; } = [];
    public List<string> Suffix { get; set; } = [];
}

internal sealed class ConversionException(string message) : Exception(message);

internal static class RecipeJson
{
    internal static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
}

internal sealed class SourceRange
{
    public string Input { get; set; } = "";
    public string NormalizedSha256 { get; set; } = "";
    public int Offset { get; set; }
    public int Length { get; set; }
}
