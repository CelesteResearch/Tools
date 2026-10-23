using System.Security.Cryptography;
using Celeste.Formats.Graphics.Atlas;
using Celeste.Formats.Graphics.Textures;
using Celeste.Graphics.Content.Textures;

internal static class TouchArtwork
{
    private static readonly (string File, string Entry)[] Controls =
    {
        ("up", "controls/directions/0x-1"),
        ("down", "controls/directions/0x1"),
        ("left", "controls/directions/-1x0"),
        ("right", "controls/directions/1x0"),
        ("jump", "controls/xb1/a"),
        ("dash", "controls/xb1/b"),
        ("grab", "controls/xb1/leftshoulder"),
        ("pause", "controls/xb1/start"),
        ("favicon", "collectables/strawberry")
    };

    internal static object[] Write(string gameContentDirectory, string outputDirectory)
    {
        string directory = Path.GetFullPath(Path.Combine(gameContentDirectory, "Graphics/Atlases"));
        var atlas = AtlasMetadataCodec.ReadMeta(Path.Combine(directory, "Gui.meta"));
        var pages = new Dictionary<string, TextureData>(StringComparer.Ordinal);
        var pending = new List<(string File, byte[] Png, int Width, int Height, string Entry)>();
        foreach (var (file, name) in Controls)
        {
            var entry = atlas.Entries[name];
            if (!pages.TryGetValue(entry.Page, out var page))
            {
                string path = Path.GetFullPath(Path.Combine(directory, entry.Page));
                if (!path.StartsWith(directory + Path.DirectorySeparatorChar,
                        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                    throw new InvalidDataException("GUI atlas page escapes its directory.");
                pages.Add(entry.Page, page = TextureDataCodec.Read(path));
            }

            int offsetX = checked((int)entry.OffsetX), offsetY = checked((int)entry.OffsetY);
            if (entry.Width < 0 || entry.Height < 0 || entry.X < 0 || entry.Y < 0 ||
                (long)entry.X + entry.Width > page.Width || (long)entry.Y + entry.Height > page.Height ||
                entry.FrameWidth < 1 || entry.FrameHeight < 1 || (long)entry.FrameWidth * entry.FrameHeight > 1048576 ||
                offsetX < 0 || offsetY < 0 || (long)offsetX + entry.Width > entry.FrameWidth ||
                (long)offsetY + entry.Height > entry.FrameHeight)
                throw new InvalidDataException("Invalid GUI atlas frame bounds.");
            var rgba = new byte[checked(entry.FrameWidth * entry.FrameHeight * 4)];
            for (int y = 0; y < entry.Height; y++)
            {
                int source = ((entry.Y + y) * page.Width + entry.X) * 4;
                int destination = ((offsetY + y) * entry.FrameWidth + offsetX) * 4;
                for (int x = 0; x < entry.Width; x++, source += 4, destination += 4)
                {
                    int alpha = page.Rgba[source + 3];
                    rgba[destination + 3] = (byte)alpha;
                    if (alpha == 0) continue;
                    // The GUI atlas is premultiplied; PNG stores straight-alpha colors.
                    for (int channel = 0; channel < 3; channel++)
                        rgba[destination + channel] = (byte)Math.Min(255,
                            (page.Rgba[source + channel] * 255 + alpha / 2) / alpha);
                }
            }

            pending.Add((file + ".png", PngImage.Encode(entry.FrameWidth, entry.FrameHeight, rgba),
                entry.FrameWidth, entry.FrameHeight, name));
        }

        string output = Path.GetFullPath(outputDirectory);
        Directory.CreateDirectory(output);
        foreach (var image in pending)
        {
            string path = Path.Combine(output, image.File);
            if (File.Exists(path) && File.ReadAllBytes(path).AsSpan().SequenceEqual(image.Png)) continue;
            string temporary = path + ".restore.tmp";
            try
            {
                File.WriteAllBytes(temporary, image.Png);
                File.Move(temporary, path, true);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }

        return pending.Select(image => (object)new
        {
            path = image.File,
            atlasEntry = image.Entry,
            width = image.Width,
            height = image.Height,
            sha256 = Convert.ToHexStringLower(SHA256.HashData(image.Png))
        }).ToArray();
    }
}
