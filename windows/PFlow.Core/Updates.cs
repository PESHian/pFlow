using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PFlow.Core;

public sealed record UpdateOffer(string Version, string Url, long Bytes, string Sha256);
public static class ReleaseUpdates
{
    public const string FeedUrl = "https://raw.githubusercontent.com/PESHian/pFlow/main/updates/feed.json";
    public const string PublicKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDVaJOvypkrygYKjZvGPzgLbHLa/eB3jkV34eeROTV076LiQrRX7T8YD7JH0P15YXeZPaC998aq/1Vw7RV/aK1g==";
    public static Version VersionOf(string value) => Regex.IsMatch(value, @"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$") && Version.TryParse(value, out var version) ? version : throw new InvalidDataException("Invalid update version.");
    public static UpdateOffer? Read(byte[] feed, string signature, string platform, string currentVersion)
    {
        if (feed.Length > 65536) throw new InvalidDataException("The update list is too large.");
        using var key = ECDsa.Create(); key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(PublicKey), out _);
        if (!key.VerifyData(feed, Convert.FromBase64String(signature.Trim()), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) throw new InvalidDataException("The update signature could not be verified.");
        using var doc = JsonDocument.Parse(feed);
        if (doc.RootElement.GetProperty("schema").GetInt32() != 1) throw new InvalidDataException("This update list is not supported.");
        if (!doc.RootElement.GetProperty("targets").TryGetProperty(platform, out var target)) return null;
        var offer = target.Deserialize<UpdateOffer>(StateStore.Json) ?? throw new InvalidDataException("The update is incomplete.");
        var version = VersionOf(offer.Version);
        if (!Uri.TryCreate(offer.Url, UriKind.Absolute, out var url) || url.Scheme != "https" || url.Host != "github.com" || !url.IsDefaultPort || !string.IsNullOrEmpty(url.UserInfo) || url.Query.Length != 0 || url.Fragment.Length != 0 || !Regex.IsMatch(url.AbsolutePath, @"^/PESHian/pFlow/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") || !Regex.IsMatch(offer.Sha256, "^[0-9a-f]{64}$") || offer.Bytes <= 0 || offer.Bytes > 536870912) throw new InvalidDataException("The update download is invalid.");
        string expected = platform == "mac-arm64" ? $"pFlow-Mac-{offer.Version}-testing.dmg" : $"pFlow-Windows-{platform[8..]}-{offer.Version}-update.zip";
        if (!url.AbsolutePath.EndsWith("/" + expected, StringComparison.Ordinal)) throw new InvalidDataException("The update does not match this device.");
        return version > VersionOf(currentVersion) ? offer : null;
    }
    public static bool DownloadHost(Uri url) => url.Scheme == "https" && url.IsDefaultPort && url.UserInfo.Length == 0 && new[] { "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "raw.githubusercontent.com" }.Contains(url.Host);
    public static void Extract(string archive, string destination)
    {
        if (Directory.Exists(destination)) throw new IOException("The update folder already exists.");
        Directory.CreateDirectory(destination);
        using var zip = ZipFile.OpenRead(archive);
        if (zip.Entries.Count > 4096) throw new InvalidDataException("The update contains too many files.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long total = 0;
        foreach (var entry in zip.Entries) {
            string name = entry.FullName;
            if ((entry.ExternalAttributes >> 16 & 0xF000) == 0xA000 || (entry.ExternalAttributes & 0x400) != 0 || !SafePath(name.TrimEnd('/')) || !names.Add(name.TrimEnd('/')) || (total += entry.Length) > 1073741824 || entry.Length > 268435456) throw new InvalidDataException("The update archive is invalid.");
            string path = Path.Combine(destination, name.Replace('/', Path.DirectorySeparatorChar));
            if (name.EndsWith('/')) { Directory.CreateDirectory(path); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var source = entry.Open(); using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            byte[] buffer = new byte[131072]; long written = 0; int count;
            while ((count = source.Read(buffer)) > 0) { if ((written += count) > entry.Length) throw new InvalidDataException("An update entry is larger than expected."); output.Write(buffer, 0, count); }
            if (written != entry.Length) throw new InvalidDataException("An update entry is incomplete.");
        }
        var manifest = Path.Combine(destination, "package-hashes.json");
        if (new FileInfo(manifest).Length > 1048576) throw new InvalidDataException("The update manifest is too large.");
        var hashes = JsonSerializer.Deserialize<List<PackageFile>>(File.ReadAllText(manifest), StateStore.Json) ?? throw new InvalidDataException("Missing update manifest.");
        var expectedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "package-hashes.json" };
        foreach (var file in hashes) {
            if (!SafePath(file.Path) || !expectedNames.Add(file.Path) || !Regex.IsMatch(file.Sha256, "^[0-9a-f]{64}$")) throw new InvalidDataException("Invalid update file manifest.");
            using var stream = File.OpenRead(Path.Combine(destination, file.Path));
            if (Convert.ToHexStringLower(SHA256.HashData(stream)) != file.Sha256) throw new InvalidDataException("An update file is damaged.");
        }
        if (!expectedNames.SetEquals(Directory.EnumerateFiles(destination, "*", SearchOption.AllDirectories).Select(path => Path.GetRelativePath(destination, path).Replace('\\', '/')))) throw new InvalidDataException("The update has unexpected files.");
    }
    static bool SafePath(string name) => name.Length is > 0 and < 240 && name.Split('/').All(part => Regex.IsMatch(part, @"^[A-Za-z0-9_][A-Za-z0-9._ -]*$") && part.TrimEnd(' ', '.') == part && !Regex.IsMatch(part, @"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", RegexOptions.IgnoreCase));
    sealed record PackageFile(string Path, string Sha256);
}

public sealed class UpdateClient : IDisposable
{
    readonly HttpClient http;
    public UpdateClient(HttpMessageHandler? handler = null) { http = new HttpClient(handler ?? new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(20) }) { Timeout = TimeSpan.FromMinutes(30) }; http.DefaultRequestHeaders.UserAgent.ParseAdd("pFlow-update/1"); http.DefaultRequestHeaders.CacheControl = new() { NoCache = true }; }
    async Task<HttpResponseMessage> Get(Uri url, CancellationToken cancel)
    {
        for (int n = 0; n < 5; n++) {
            if (!ReleaseUpdates.DownloadHost(url)) throw new InvalidDataException("The update redirected to an unexpected site.");
            var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308) { var next = response.Headers.Location ?? throw new InvalidDataException("Invalid update redirect."); response.Dispose(); url = next.IsAbsoluteUri ? next : new Uri(url, next); continue; }
            response.EnsureSuccessStatusCode(); return response;
        }
        throw new InvalidDataException("Too many update redirects.");
    }
    async Task<byte[]> Small(string url, CancellationToken cancel)
    {
        using var response = await Get(new Uri(url), cancel); using var stream = await response.Content.ReadAsStreamAsync(cancel); using var data = new MemoryStream(); byte[] buffer = new byte[8192]; int count;
        while ((count = await stream.ReadAsync(buffer, cancel)) > 0) { if (data.Length + count > 65536) throw new InvalidDataException("The update list is too large."); data.Write(buffer, 0, count); }
        return data.ToArray();
    }
    public async Task<UpdateOffer?> Check(string platform, string currentVersion, CancellationToken cancel)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel); timeout.CancelAfter(TimeSpan.FromSeconds(20));
        return ReleaseUpdates.Read(await Small(ReleaseUpdates.FeedUrl, timeout.Token), System.Text.Encoding.ASCII.GetString(await Small(ReleaseUpdates.FeedUrl + ".sig", timeout.Token)), platform, currentVersion);
    }
    public async Task Download(UpdateOffer offer, string file, IProgress<double> progress, CancellationToken cancel)
    {
        using var response = await Get(new Uri(offer.Url), cancel);
        if (response.Content.Headers.ContentLength is { } size && size != offer.Bytes) throw new InvalidDataException("The update size does not match.");
        using var input = await response.Content.ReadAsStreamAsync(cancel); using var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write); using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[131072]; long total = 0; int count;
        while ((count = await input.ReadAsync(buffer, cancel)) > 0) { if ((total += count) > offer.Bytes) throw new InvalidDataException("The update is larger than expected."); hash.AppendData(buffer, 0, count); await output.WriteAsync(buffer.AsMemory(0, count), cancel); progress.Report((double)total / offer.Bytes); }
        if (total != offer.Bytes || Convert.ToHexStringLower(hash.GetHashAndReset()) != offer.Sha256) throw new InvalidDataException("The update is incomplete or damaged. Your installed app was not changed.");
    }
    public void Dispose() => http.Dispose();
}
