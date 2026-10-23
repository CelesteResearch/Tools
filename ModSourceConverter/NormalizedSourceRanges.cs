using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Celeste.Tools.ModSourceConverter;

// A range is data copied from a fully locked user input, never stored third-party text.
internal sealed class NormalizedSourceRanges(IReadOnlyDictionary<string, CompilationUnitSyntax> inputs)
{
    private readonly Dictionary<string, NormalizedInput> cache = new(StringComparer.Ordinal);

    private sealed record NormalizedInput(string Text, string Sha256);

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal string Extract(SourceRange range)
    {
        LockedPaths.RequireHash(range.NormalizedSha256);
        if (!cache.TryGetValue(range.Input, out NormalizedInput? input))
        {
            if (!inputs.TryGetValue(range.Input, out CompilationUnitSyntax? syntax))
                throw new ConversionException("Source range references an unknown input.");
            string normalized = syntax.NormalizeWhitespace(indentation: "    ", eol: "\n").ToFullString();
            input = new NormalizedInput(normalized, LockedPaths.Hash(StrictUtf8.GetBytes(normalized)));
            cache.Add(range.Input, input);
        }

        if (input.Sha256 != range.NormalizedSha256)
            throw new ConversionException("Normalized compilation-unit SHA-256 lock mismatch.");
        if (range.Offset < 0 || range.Length <= 0 || range.Length > input.Text.Length ||
            range.Offset > input.Text.Length - range.Length)
            throw new ConversionException("Source range is outside the locked compilation unit.");
        // Offset/Length count .NET UTF-16 code units. Strict UTF-8 rejects split surrogate pairs.
        string text = input.Text.Substring(range.Offset, range.Length);
        _ = StrictUtf8.GetByteCount(text);
        return text;
    }
}
