using System.Buffers.Binary;
using System.IO.Compression;

internal static class PngImage
{
    internal static byte[] Encode(int width, int height, byte[] rgba)
    {
        using var output = new MemoryStream();
        output.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        Span<byte> header = stackalloc byte[13];
        header.Clear();
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header[4..], height);
        header[8] = 8;
        header[9] = 6;
        WriteChunk(output, "IHDR"u8, header);
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, true))
        {
            int stride = checked(width * 4);
            for (int row = 0; row < height; row++)
            {
                zlib.WriteByte(0);
                zlib.Write(rgba.AsSpan(row * stride, stride));
            }
        }

        WriteChunk(output, "IDAT"u8, compressed.ToArray());
        WriteChunk(output, "IEND"u8, ReadOnlySpan<byte>.Empty);
        return output.ToArray();
    }

    private static void WriteChunk(Stream output, ReadOnlySpan<byte> type, ReadOnlySpan<byte> bytes)
    {
        Span<byte> value = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(value, bytes.Length);
        output.Write(value);
        output.Write(type);
        output.Write(bytes);
        uint crc = uint.MaxValue;
        foreach (byte item in type) crc = UpdateCrc(crc, item);
        foreach (byte item in bytes) crc = UpdateCrc(crc, item);
        BinaryPrimitives.WriteUInt32BigEndian(value, ~crc);
        output.Write(value);
    }

    private static uint UpdateCrc(uint crc, byte value)
    {
        crc ^= value;
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0);
        return crc;
    }
}
