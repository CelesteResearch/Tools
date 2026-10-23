using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Celeste.Tools.ModSourceConverter;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            var options = new Dictionary<string, string>(StringComparer.Ordinal);
            bool check = false;
            for (int index = 0; index < args.Length; ++index)
            {
                if (args[index] == "--check")
                {
                    if (check) throw new ConversionException("Duplicate check argument.");
                    check = true;
                    continue;
                }

                if (args[index] is not ("--input-root" or "--recipe" or "--output-root") ||
                    index + 1 == args.Length || !options.TryAdd(args[index], args[++index]))
                    throw new ConversionException(
                        "Expected --input-root DIR --recipe FILE --output-root DIR [--check].");
            }

            if (options.Count != 3) throw new ConversionException("Three named paths are required.");
            string inputRoot = LockedPaths.Root(options["--input-root"], true);
            string outputRoot = LockedPaths.Root(options["--output-root"], false);
            if (LockedPaths.Comparer.Equals(inputRoot, outputRoot) || LockedPaths.Within(inputRoot, outputRoot) ||
                LockedPaths.Within(outputRoot, inputRoot))
                throw new ConversionException("Input and output roots must be separate.");
            string recipePath = Path.GetFullPath(options["--recipe"]);
            LockedPaths.RejectLinks(recipePath);
            Recipe recipe = JsonSerializer.Deserialize<Recipe>(File.ReadAllBytes(recipePath), RecipeJson.Options)
                            ?? throw new ConversionException("Recipe is empty.");
            if (recipe.SchemaVersion != 1 || recipe.Newline != "lf" || recipe.Inputs.Count == 0 ||
                recipe.Outputs.Count == 0)
                throw new ConversionException("Unsupported or incomplete recipe.");
            var inputs = new Dictionary<string, CompilationUnitSyntax>(StringComparer.Ordinal);
            foreach (RecipeInput input in recipe.Inputs)
            {
                LockedPaths.RequireHash(input.Sha256);
                byte[] bytes = File.ReadAllBytes(LockedPaths.Resolve(inputRoot, input.Path));
                if (LockedPaths.Hash(bytes) != input.Sha256)
                    throw new ConversionException("Input SHA-256 lock mismatch.");
                string source = new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF');
                CompilationUnitSyntax syntax = CSharpSyntaxTree.ParseText(source,
                    new CSharpParseOptions(LanguageVersion.CSharp14)).GetCompilationUnitRoot();
                if (syntax.GetDiagnostics().Any(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error))
                    throw new ConversionException("Input C# syntax is invalid.");
                if (string.IsNullOrWhiteSpace(input.Id) || !inputs.TryAdd(input.Id, syntax))
                    throw new ConversionException("Input identifiers must be present and unique.");
            }

            var rangeSources = new NormalizedSourceRanges(inputs);
            var outputs = new Dictionary<string, byte[]>(LockedPaths.Comparer);
            foreach (RecipeOutput output in recipe.Outputs)
            {
                LockedPaths.RequireHash(output.Sha256);
                LockedPaths.Resolve(outputRoot, output.Path);
                if (output.Segments.Count == 0) throw new ConversionException("Output has no segments.");
                var text = new StringBuilder();
                foreach (Segment segment in output.Segments)
                {
                    int alternatives = (segment.Literal != null ? 1 : 0) + (segment.Source != null ? 1 : 0) +
                                       (segment.SourceRange != null ? 1 : 0);
                    if (alternatives != 1 || segment.Indent < 0 || segment.Indent > 32)
                        throw new ConversionException(
                            "A segment requires exactly one literal, source selector or source range.");
                    string value;
                    if (segment.Source is { } selector)
                    {
                        if (!inputs.TryGetValue(selector.Input, out CompilationUnitSyntax? input))
                            throw new ConversionException("Selector references an unknown input.");
                        value = SourceSelector.Render(input, selector);
                    }
                    else if (segment.SourceRange is { } range)
                    {
                        if (segment.Indent != 0)
                            throw new ConversionException(
                                "Source ranges preserve exact whitespace and cannot be reindented.");
                        value = rangeSources.Extract(range);
                    }
                    else value = segment.Literal!;

                    value = value.Replace("\r\n", "\n").Replace('\r', '\n');
                    if (segment.Indent != 0)
                    {
                        string prefix = new(' ', segment.Indent * 4);
                        value = string.Join("\n",
                            value.Split('\n').Select(line => line.Length == 0 ? "" : prefix + line));
                    }

                    text.Append(value);
                }

                byte[] generated = new UTF8Encoding(false).GetBytes(text.ToString());
                string hash = LockedPaths.Hash(generated);
                if (hash != output.Sha256)
                    throw new ConversionException("Output SHA-256 lock mismatch for " + output.Path + "; computed " +
                                                  hash + ".");
                if (!outputs.TryAdd(output.Path, generated))
                    throw new ConversionException("Output paths must be unique.");
            }

            // Verify the complete conversion before any filesystem mutation.
            if (!check) LockedPaths.Commit(outputRoot, outputs);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                outputs = outputs.Select(output => new { path = output.Key, sha256 = LockedPaths.Hash(output.Value) })
            }, RecipeJson.Options));
            return 0;
        }
        catch (ConversionException error)
        {
            Console.Error.WriteLine("Conversion refused: " + error.Message);
            return 1;
        }
        catch (IOException error)
        {
            Console.Error.WriteLine("Conversion I/O failed (0x" + error.HResult.ToString("X8") + "): " + error.Message);
            if (error.Data["ConverterOutputRoot"] is string destination)
                Console.Error.WriteLine("Destination: " + destination);
            return 1;
        }
        catch (Exception error)
        {
            // Do not include parser text, snippets, arbitrary exception messages or stack traces.
            Console.Error.WriteLine("Conversion failed (" + error.GetType().Name + ").");
            return 1;
        }
    }
}
