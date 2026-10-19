using PFlow.Core;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

internal static class UpdateChecks
{
    public static void Run()
    {
        int passed = 0;
        void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
        void Refuses(string name, Action action) { bool refused = false; try { action(); } catch (Exception e) when (e is InvalidDataException or FormatException or JsonException or IOException) { refused = true; } Check(name, refused); }
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "UpdateVectors.json")));
        foreach (var vector in vectors.RootElement.EnumerateArray()) {
            string name = vector.GetProperty("name").GetString()!;
            byte[] data = Convert.FromBase64String(vector.GetProperty("data").GetString()!); string signature = vector.GetProperty("signature").GetString()!;
            if (name is "valid" or "Mac foreign host") Check(name + " valid Windows offer", ReleaseUpdates.Read(data, signature, "windows-x64", "0.1.10")?.Version == "0.1.11");
            else Refuses(name, () => ReleaseUpdates.Read(data, signature, "windows-x64", "0.1.10"));
            if (name == "valid") {
                Check("equal version is current", ReleaseUpdates.Read(data, signature, "windows-x64", "0.1.11") == null);
                Check("newer installed version cannot downgrade", ReleaseUpdates.Read(data, signature, "windows-x64", "1.0.0") == null);
                Check("unpublished processor has no update", ReleaseUpdates.Read(data, signature, "windows-x86", "0.1.10") == null);
                data[0] ^= 1; Refuses("tampered signed feed", () => ReleaseUpdates.Read(data, signature, "windows-x64", "0.1.10"));
            }
        }
        foreach (string version in new[] { "0.1", "-1.2.3", "1.02.3", "1.2.3-preview", "1.2.3.4", "2147483648.0.0" }) Refuses("invalid version " + version, () => ReleaseUpdates.VersionOf(version));
        Check("versions compare numerically", ReleaseUpdates.VersionOf("0.1.12") > ReleaseUpdates.VersionOf("0.1.9"));
        Check("redirect to release CDN allowed", ReleaseUpdates.DownloadHost(new Uri("https://release-assets.githubusercontent.com/example")));
        Check("redirect to untrusted host refused", !ReleaseUpdates.DownloadHost(new Uri("https://github.com.attacker.example/file")) && !ReleaseUpdates.DownloadHost(new Uri("http://github.com/file")));
        string root = Path.Combine(Path.GetTempPath(), "pflow-update-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try {
            string Make(string name, params (string Path, string Text)[] entries) {
                string file = Path.Combine(root, name + ".zip"); using var zip = ZipFile.Open(file, ZipArchiveMode.Create);
                foreach (var entry in entries) { using var writer = new StreamWriter(zip.CreateEntry(entry.Path).Open()); writer.Write(entry.Text); }
                return file;
            }
            string manifest = JsonSerializer.Serialize(new[] { new { path = "fictional.txt", sha256 = Convert.ToHexStringLower(SHA256.HashData("Fictional update."u8)) } });
            var good = Make("good", ("fictional.txt", "Fictional update."), ("package-hashes.json", manifest));
            ReleaseUpdates.Extract(good, Path.Combine(root, "good")); Check("valid archive hashes and file set checked", File.ReadAllText(Path.Combine(root, "good", "fictional.txt")) == "Fictional update.");
            foreach (string name in new[] { "../outside.txt", "/absolute.txt", "C:/outside.txt", "folder\\outside.txt", "file.txt:stream", "con.txt", "folder./file.txt" }) {
                string zip = Make(Guid.NewGuid().ToString("N"), (name, "Must not write"));
                Refuses("unsafe archive path " + name, () => ReleaseUpdates.Extract(zip, Path.Combine(root, Guid.NewGuid().ToString("N"))));
            }
            Refuses("changed file rejected", () => ReleaseUpdates.Extract(Make("changed", ("fictional.txt", "Changed"), ("package-hashes.json", manifest)), Path.Combine(root, "changed")));
            Refuses("unlisted executable rejected", () => ReleaseUpdates.Extract(Make("extra", ("fictional.txt", "Fictional update."), ("extra.exe", "Never run"), ("package-hashes.json", manifest)), Path.Combine(root, "extra")));
            Refuses("case-insensitive duplicate rejected", () => ReleaseUpdates.Extract(Make("duplicate", ("same.txt", "one"), ("SAME.TXT", "two")), Path.Combine(root, "duplicate")));
            string symbolic = Path.Combine(root, "symlink.zip"); using (var z = ZipFile.Open(symbolic, ZipArchiveMode.Create)) { var e = z.CreateEntry("link"); e.ExternalAttributes = unchecked((int)0xA1FF0000); using var w = new StreamWriter(e.Open()); w.Write("../outside"); }
            Refuses("archive symlink rejected", () => ReleaseUpdates.Extract(symbolic, Path.Combine(root, "symlink")));
        } finally { Directory.Delete(root, true); }
        Console.WriteLine($"{passed} update checks passed.");
    }
}
