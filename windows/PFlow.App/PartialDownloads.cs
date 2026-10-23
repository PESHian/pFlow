using System.IO;
using System.Text.RegularExpressions;

namespace PFlow.Windows;

/// A download writes to "<file>.<guid>.download" beside its target and removes it when it ends;
/// one left by a crash or a power cut is removed at the next app start. Only that pattern, only
/// in pFlow's own folder; the model files themselves are never touched.
internal static class PartialDownloads
{
    public static string TempPath(string folder, string fileName) => Path.Combine(folder, fileName + "." + Guid.NewGuid() + ".download");
    public static int Sweep(string folder, string fileName)
    {
        if (!Directory.Exists(folder)) return 0;
        var pattern = new Regex("^" + Regex.Escape(fileName) + @"\.[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\.download$");
        int removed = 0;
        foreach (string path in Directory.EnumerateFiles(folder, fileName + ".*.download")) {
            if (!pattern.IsMatch(Path.GetFileName(path))) continue;
            try { File.Delete(path); removed++; } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return removed;
    }
}
