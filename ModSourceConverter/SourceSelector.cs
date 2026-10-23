using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Celeste.Tools.ModSourceConverter;

internal static class SourceSelector
{
    internal static string Render(CompilationUnitSyntax input, Selector selector)
    {
        if (selector.Format is not ("preserve" or "normalize"))
            throw new ConversionException("Unknown source formatting mode.");
        if (selector.Part != "statements" && (selector.StatementStart != null || selector.StatementCount != null))
            throw new ConversionException("Statement ranges require the statements part.");
        TypeDeclarationSyntax[] types = input.DescendantNodes().OfType<TypeDeclarationSyntax>()
            .Where(type => QualifiedName(type) == selector.Type).ToArray();
        if (types.Length != 1) throw new ConversionException("Type selector must match exactly one declaration.");
        TypeDeclarationSyntax owner = types[0];
        IEnumerable<MemberDeclarationSyntax> candidates = selector.MemberKind switch
        {
            "class" => owner is ClassDeclarationSyntax ? [owner] : [],
            "constructor" => owner.Members.OfType<ConstructorDeclarationSyntax>()
                .Where(member => selector.MemberName == null || member.Identifier.ValueText == selector.MemberName),
            "method" => owner.Members.OfType<MethodDeclarationSyntax>()
                .Where(member => member.Identifier.ValueText == selector.MemberName),
            "field" => owner.Members.OfType<FieldDeclarationSyntax>()
                .Where(member =>
                    member.Declaration.Variables.Any(variable => variable.Identifier.ValueText == selector.MemberName)),
            "enum" => owner.Members.OfType<EnumDeclarationSyntax>()
                .Where(member => member.Identifier.ValueText == selector.MemberName),
            "struct" => owner.Members.OfType<StructDeclarationSyntax>()
                .Where(member => member.Identifier.ValueText == selector.MemberName),
            "property" => owner.Members.OfType<PropertyDeclarationSyntax>()
                .Where(member => member.Identifier.ValueText == selector.MemberName),
            _ => throw new ConversionException("Unknown member selector kind.")
        };
        if (selector.MemberKind == "class" && selector.MemberName != null &&
            owner.Identifier.ValueText != selector.MemberName)
            candidates = [];
        if (selector.ParameterTypes != null)
            candidates = candidates.Where(member => ParametersMatch(member, selector.ParameterTypes));
        MemberDeclarationSyntax[] matches = candidates.ToArray();
        if (matches.Length != 1) throw new ConversionException("Member selector must match exactly one declaration.");
        MemberDeclarationSyntax selected = matches[0];
        if (selector.Part == "declarationTrailingTrivia")
        {
            if (selected is not TypeDeclarationSyntax declaration)
                throw new ConversionException("Declaration trivia requires a type selector.");
            SyntaxToken lastHeader = declaration.DescendantTokens()
                .Last(token => token.Span.End <= declaration.OpenBraceToken.SpanStart);
            string[] comments = lastHeader.TrailingTrivia.Concat(declaration.OpenBraceToken.LeadingTrivia)
                .Where(trivia => trivia.IsKind(SyntaxKind.SingleLineCommentTrivia) ||
                                 trivia.IsKind(SyntaxKind.MultiLineCommentTrivia) ||
                                 trivia.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia) ||
                                 trivia.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia))
                .Select(trivia => trivia.ToFullString()).ToArray();
            if (comments.Length == 0) throw new ConversionException("Selected declaration has no trailing comments.");
            return Dedent(string.Join("\n", comments));
        }

        var rewriter = new ApiRewriter(selector.Maps);
        if (selector.Part == "parameters")
        {
            if (selected is not BaseMethodDeclarationSyntax method)
                throw new ConversionException("Parameter selection requires a method or constructor.");
            return string.Join(", ", method.ParameterList.Parameters.Select(parameter =>
                rewriter.Visit(parameter)!.WithoutTrivia().NormalizeWhitespace(indentation: "    ", eol: "\n")
                    .ToFullString()));
        }

        IEnumerable<SyntaxNode> nodes = selector.Part switch
        {
            "full" => [selected],
            "body" => [Body(selected)],
            "statements" => Statements(selected, selector),
            "initializer" => [Initializer(selected, selector.MemberName)],
            "attributes" => selected.ChildNodes().OfType<AttributeListSyntax>(),
            "lambdaBody" => [LambdaBody(selected, selector.LambdaIndex)],
            _ => throw new ConversionException("Unknown source selector part.")
        };
        SyntaxNode[] parts = nodes.ToArray();
        if (parts.Length == 0) throw new ConversionException("Selected source part is empty.");
        return string.Join("\n", parts.Select(node =>
        {
            SyntaxNode rewritten = rewriter.Visit(node) ??
                                   throw new ConversionException("Rewriting removed selected source.");
            if (rewritten.ContainsDiagnostics)
                throw new ConversionException("Rewritten source has syntax diagnostics.");
            string text = selector.Format == "normalize"
                ? rewritten.NormalizeWhitespace(indentation: "    ", eol: "\n").ToFullString()
                : rewritten.ToFullString();
            return Dedent(text);
        }));
    }

    private static IEnumerable<SyntaxNode> Statements(MemberDeclarationSyntax member, Selector selector)
    {
        SyntaxList<StatementSyntax> statements = Body(member).Statements;
        int start = selector.StatementStart ?? 0;
        if (start < 0 || start >= statements.Count)
            throw new ConversionException("Statement start is outside the locked member.");
        int count = selector.StatementCount ?? statements.Count - start;
        if (count <= 0 || count > statements.Count - start)
            throw new ConversionException("Statement count is outside the locked member.");
        return statements.Skip(start).Take(count);
    }

    private static bool ParametersMatch(MemberDeclarationSyntax node, IReadOnlyList<string> expected)
    {
        if (node is not BaseMethodDeclarationSyntax method) return false;
        return method.ParameterList.Parameters
            .Select(parameter => parameter.Type == null ? "" : ApiRewriter.Key(parameter.Type))
            .SequenceEqual(expected, StringComparer.Ordinal);
    }

    private static string QualifiedName(TypeDeclarationSyntax node)
    {
        var pieces = node.Ancestors().Reverse().Select(parent => parent switch
        {
            BaseNamespaceDeclarationSyntax space => space.Name.ToString(),
            TypeDeclarationSyntax type => type.Identifier.ValueText,
            _ => null
        }).Where(piece => piece != null).Append(node.Identifier.ValueText);
        return string.Join(".", pieces);
    }

    private static BlockSyntax Body(MemberDeclarationSyntax member) => member switch
    {
        BaseMethodDeclarationSyntax { Body: { } body } => body,
        _ => throw new ConversionException("Selected member has no statement body.")
    };

    private static SyntaxNode LambdaBody(MemberDeclarationSyntax member, int? index)
    {
        LambdaExpressionSyntax[] lambdas = member.DescendantNodes().OfType<LambdaExpressionSyntax>().ToArray();
        if (index is not >= 0 || index >= lambdas.Length)
            throw new ConversionException("Lambda selector is outside the locked member.");
        return lambdas[index.Value].Body;
    }

    private static SyntaxNode Initializer(MemberDeclarationSyntax member, string? name) => member switch
    {
        ConstructorDeclarationSyntax { Initializer: { } initializer } => initializer,
        FieldDeclarationSyntax field => field.Declaration.Variables
            .Single(variable => variable.Identifier.ValueText == name)
            .Initializer?.Value ?? throw new ConversionException("Selected field has no initializer."),
        _ => throw new ConversionException("Selected member has no supported initializer.")
    };

    private static string Dedent(string text)
    {
        string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Trim('\n').Split('\n');
        int indent = lines.Where(line => !string.IsNullOrWhiteSpace(line))
            .Select(line => line.TakeWhile(character => character is ' ' or '\t').Count()).DefaultIfEmpty(0).Min();
        return string.Join("\n", lines.Select(line => string.IsNullOrWhiteSpace(line) ? "" : line[indent..]));
    }
}
