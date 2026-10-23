using System.Text.Json;

if (args.Length != 2)
{
    Console.Error.WriteLine("Usage: WebTouchArtwork <game-content-directory> <output-directory>");
    return 2;
}

var files = TouchArtwork.Write(args[0], args[1]);
Console.WriteLine(JsonSerializer.Serialize(new { status = "pass", files }));
return 0;
