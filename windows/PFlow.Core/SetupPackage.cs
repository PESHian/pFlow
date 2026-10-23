using System.Buffers.Binary;
using System.Text;

namespace PFlow.Core;

/// How `pFlow Setup.exe` carries its package: the setup program, then the
/// universal ZIP (unchanged), then a 16-byte trailer naming where the ZIP
/// starts. Setup reads the trailer from the end of its own file; nothing else
/// in the file is searched, so a ZIP inside the program itself cannot mislead it.
public static class SetupPackage
{
    public const int TrailerLength = 16;
    static readonly byte[] Magic = Encoding.ASCII.GetBytes("PFLOWSET");

    /// The trailer for a ZIP that begins `zipStart` bytes into the file.
    public static byte[] Trailer(long zipStart)
    {
        if (zipStart <= 0) throw new ArgumentOutOfRangeException(nameof(zipStart));
        var trailer = new byte[TrailerLength];
        Magic.CopyTo(trailer, 0);
        BinaryPrimitives.WriteInt64LittleEndian(trailer.AsSpan(8), zipStart);
        return trailer;
    }

    /// Where the ZIP starts, given the file's last 16 bytes and its length;
    /// null when the file carries no package (a bare setup program).
    public static long? ZipStart(ReadOnlySpan<byte> tail, long fileLength)
    {
        if (tail.Length != TrailerLength || !tail[..8].SequenceEqual(Magic)) return null;
        long start = BinaryPrimitives.ReadInt64LittleEndian(tail[8..]);
        return start > 0 && start < fileLength - TrailerLength ? start : null;
    }

    /// A ZIP entry name that may be written under the extraction folder: a
    /// relative path with no drive, no parent step and no absolute root.
    public static bool SafeEntry(string name)
    {
        if (name.Length == 0 || name.StartsWith('/') || name.StartsWith('\\') || name.Contains(':')) return false;
        var parts = name.Split('/', '\\');
        // A folder entry ends with a separator; any other empty part is a doubled separator.
        return !parts.Any(part => part == "..") && !parts.Take(parts.Length - 1).Any(part => part.Length == 0);
    }
}
