using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Celeste.Tools.ModSourceConverter;

internal sealed class ApiRewriter(Mappings maps) : CSharpSyntaxRewriter
{
    public override SyntaxNode? Visit(SyntaxNode? node)
    {
        if (node is ExpressionSyntax expression && maps.Expressions.TryGetValue(Key(expression), out string? mapped))
            return ParsedExpression(mapped).WithTriviaFrom(expression);
        if (node is TypeSyntax type && IsTypeReference(type) &&
            maps.Types.TryGetValue(Key(type), out string? replacement))
            return ParsedType(replacement).WithTriviaFrom(type);
        return base.Visit(node);
    }

    public override SyntaxToken VisitToken(SyntaxToken token)
    {
        if (token.IsKind(SyntaxKind.IdentifierToken) && maps.Tokens.TryGetValue(token.ValueText, out string? value))
        {
            if (!SyntaxFacts.IsValidIdentifier(value))
                throw new ConversionException("Invalid identifier-token mapping.");
            return SyntaxFactory.Identifier(token.LeadingTrivia, value, token.TrailingTrivia);
        }

        return base.VisitToken(token);
    }

    public override SyntaxNode? VisitIdentifierName(IdentifierNameSyntax node)
    {
        if (!maps.Identifiers.TryGetValue(node.Identifier.ValueText, out string? replacement))
            return base.VisitIdentifierName(node);
        return ParsedExpression(replacement).WithTriviaFrom(node);
    }

    public override SyntaxNode? VisitMemberAccessExpression(MemberAccessExpressionSyntax node)
    {
        if (maps.MemberAccess.TryGetValue(Key(node), out string? replacement))
            return ParsedExpression(replacement).WithTriviaFrom(node);
        return base.VisitMemberAccessExpression(node);
    }

    public override SyntaxNode VisitInvocationExpression(InvocationExpressionSyntax node)
    {
        var result = (InvocationExpressionSyntax)base.VisitInvocationExpression(node)!;
        if (maps.Invocations.TryGetValue(Key(node.Expression), out string? replacement))
            return result.WithExpression(ParsedExpression(replacement).WithTriviaFrom(node.Expression));
        return result;
    }

    public override SyntaxNode VisitArgument(ArgumentSyntax node)
    {
        var result = (ArgumentSyntax)base.VisitArgument(node)!;
        if (node.NameColon != null && maps.RemoveArgumentNames.Contains(node.NameColon.Name.Identifier.ValueText,
                StringComparer.Ordinal))
            return result.WithNameColon(null);
        return result;
    }

    public override SyntaxNode VisitObjectCreationExpression(ObjectCreationExpressionSyntax node)
    {
        var result = (ObjectCreationExpressionSyntax)base.VisitObjectCreationExpression(node)!;
        if (!maps.Constructors.TryGetValue(Key(node.Type), out ConstructorArguments? arguments)) return result;
        IEnumerable<ArgumentSyntax> original = result.ArgumentList?.Arguments ?? [];
        return result.WithArgumentList(SyntaxFactory.ArgumentList(SyntaxFactory.SeparatedList(
            arguments.Prefix.Select(value => SyntaxFactory.Argument(ParsedExpression(value)))
                .Concat(original)
                .Concat(arguments.Suffix.Select(value => SyntaxFactory.Argument(ParsedExpression(value)))))));
    }

    public override SyntaxNode VisitConstructorInitializer(ConstructorInitializerSyntax node)
    {
        var result = (ConstructorInitializerSyntax)base.VisitConstructorInitializer(node)!;
        if (maps.InitializerSuffix.Count == 0) return result;
        return result.WithArgumentList(result.ArgumentList.AddArguments(maps.InitializerSuffix
            .Select(value => SyntaxFactory.Argument(ParsedExpression(value))).ToArray()));
    }

    public override SyntaxNode? VisitAssignmentExpression(AssignmentExpressionSyntax node)
    {
        if (!maps.AssignmentCalls.TryGetValue(Key(node.Left), out string? target))
            return base.VisitAssignmentExpression(node);
        if (!node.IsKind(SyntaxKind.SimpleAssignmentExpression))
            throw new ConversionException("Assignment-call mapping requires a simple assignment.");
        if (node.Parent is not ExpressionStatementSyntax)
            throw new ConversionException("Assignment-call mapping requires an independent expression statement.");
        var right = (ExpressionSyntax)Visit(node.Right)!;
        return SyntaxFactory.InvocationExpression(ParsedExpression(target),
                SyntaxFactory.ArgumentList(SyntaxFactory.SingletonSeparatedList(SyntaxFactory.Argument(right))))
            .WithTriviaFrom(node);
    }

    internal static string Key(SyntaxNode node) => node.WithoutTrivia().NormalizeWhitespace().ToFullString();

    private static bool IsTypeReference(TypeSyntax node) => node.Parent switch
    {
        QualifiedNameSyntax parent => IsTypeReference(parent),
        AliasQualifiedNameSyntax parent => parent.Name == node && IsTypeReference(parent),
        NullableTypeSyntax or ArrayTypeSyntax or PointerTypeSyntax or RefTypeSyntax => true,
        TypeArgumentListSyntax => true,
        VariableDeclarationSyntax parent => parent.Type == node,
        ForEachStatementSyntax parent => parent.Type == node,
        DeclarationExpressionSyntax parent => parent.Type == node,
        ParameterSyntax parent => parent.Type == node,
        FunctionPointerParameterSyntax parent => parent.Type == node,
        ExplicitInterfaceSpecifierSyntax parent => parent.Name == node,
        AttributeSyntax parent => parent.Name == node,
        MethodDeclarationSyntax parent => parent.ReturnType == node,
        LocalFunctionStatementSyntax parent => parent.ReturnType == node,
        PropertyDeclarationSyntax parent => parent.Type == node,
        IndexerDeclarationSyntax parent => parent.Type == node,
        EventDeclarationSyntax parent => parent.Type == node,
        OperatorDeclarationSyntax parent => parent.ReturnType == node,
        ConversionOperatorDeclarationSyntax parent => parent.Type == node,
        ObjectCreationExpressionSyntax parent => parent.Type == node,
        ArrayCreationExpressionSyntax parent => parent.Type == node,
        StackAllocArrayCreationExpressionSyntax parent => parent.Type == node,
        ParenthesizedLambdaExpressionSyntax parent => parent.ReturnType == node,
        RefValueExpressionSyntax parent => parent.Type == node,
        CastExpressionSyntax parent => parent.Type == node,
        TypeOfExpressionSyntax parent => parent.Type == node,
        DefaultExpressionSyntax parent => parent.Type == node,
        SizeOfExpressionSyntax parent => parent.Type == node,
        DeclarationPatternSyntax parent => parent.Type == node,
        RecursivePatternSyntax parent => parent.Type == node,
        TypePatternSyntax parent => parent.Type == node,
        CatchDeclarationSyntax parent => parent.Type == node,
        TupleElementSyntax parent => parent.Type == node,
        TypeConstraintSyntax parent => parent.Type == node,
        BaseTypeSyntax parent => parent.Type == node,
        BinaryExpressionSyntax parent => parent.Right == node &&
                                         (parent.IsKind(SyntaxKind.AsExpression) ||
                                          parent.IsKind(SyntaxKind.IsExpression)),
        _ => false
    };

    private static ExpressionSyntax ParsedExpression(string text)
    {
        ExpressionSyntax expression = SyntaxFactory.ParseExpression(text);
        if (expression.ContainsDiagnostics) throw new ConversionException("Invalid expression mapping.");
        return expression;
    }

    private static TypeSyntax ParsedType(string text)
    {
        TypeSyntax type = SyntaxFactory.ParseTypeName(text);
        if (type.ContainsDiagnostics) throw new ConversionException("Invalid type mapping.");
        return type;
    }
}
