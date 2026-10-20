using System.Buffers.Binary;
using System.Text;

namespace PFlow.Core;

/// The live part of the private stdin/stdout protocol with `pflow-whisper.exe`
/// (windows/native/worker.cpp). Every live frame carries the protocol version,
/// the take (session) and the window number (sequence); every length is
/// bounded before anything is allocated. All numbers are little-endian.
///   hello:    u32 "PFW2", u32 threads, u32 length + UTF-8 model path
///   ready:    u32 1, f64 load ms, u32 version            | failed: u32 3, u32 length + message
///   live:     u32 "PFS1", u32 version, u32 session, u32 sequence, u32 length + language, u32 count + count f32 samples
///   cancel:   u32 "PFC1", u32 version, u32 session, u32 sequence   (no reply of its own)
///   result:   u32 4, u32 version, u32 session, u32 sequence, u32 n, n x (i32 from ms, i32 to ms, f32 no-speech, u32 length + text), f64 ms
///   error:    u32 5, u32 version, u32 session, u32 sequence, u32 length + message
/// Each live request gets exactly one result or error, also when it is canceled.
public static class LiveWorkerProtocol
{
    public const uint Hello = 0x32574650, Request = 0x31534650, Cancel = 0x31434650;
    public const uint Version = 2, Ready = 1, Result = 4, Error = 5;
    public const int MaximumSamples = 30 * 16_000, MaximumSegments = 512, MaximumText = 4096, MaximumTotalText = 256 * 1024, MaximumLanguage = 64;
    /// Responses for older windows that may be skipped before giving up.
    public const int MaximumStale = 2;

    public sealed record Response(uint Session, uint Sequence, IReadOnlyList<WhisperWindowSegment>? Segments, string? Error, double Milliseconds);

    public static byte[] EncodeRequest(uint session, uint sequence, string language, ReadOnlySpan<float> samples)
    {
        byte[] name = Encoding.UTF8.GetBytes(language);
        if (name.Length == 0 || name.Length > MaximumLanguage || language.Contains('\0')) throw new InvalidDataException("A speech setting is too long or invalid.");
        if (samples.Length == 0 || samples.Length > MaximumSamples) throw new InvalidDataException("A live audio window is empty or too long.");
        var bytes = new byte[24 + name.Length + samples.Length * 4];
        var span = bytes.AsSpan();
        BinaryPrimitives.WriteUInt32LittleEndian(span, Request);
        BinaryPrimitives.WriteUInt32LittleEndian(span[4..], Version);
        BinaryPrimitives.WriteUInt32LittleEndian(span[8..], session);
        BinaryPrimitives.WriteUInt32LittleEndian(span[12..], sequence);
        BinaryPrimitives.WriteUInt32LittleEndian(span[16..], (uint)name.Length);
        name.CopyTo(span[20..]);
        int at = 20 + name.Length;
        BinaryPrimitives.WriteUInt32LittleEndian(span[at..], (uint)samples.Length); at += 4;
        for (int index = 0; index < samples.Length; index++, at += 4) BinaryPrimitives.WriteSingleLittleEndian(span[at..], samples[index]);
        return bytes;
    }

    public static byte[] EncodeCancel(uint session, uint sequence)
    {
        var bytes = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, Cancel);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), Version);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), session);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(12), sequence);
        return bytes;
    }

    /// Reads the reply to (session, sequence). A reply for an older window is
    /// discarded; anything malformed, oversized or from another protocol
    /// version throws, and the caller must end the worker.
    public static async Task<(Response Response, int Discarded)> ReadReply(Stream input, uint session, uint sequence, CancellationToken cancel)
    {
        for (int discarded = 0; ; discarded++) {
            var response = await ReadResponse(input, cancel);
            if (response.Session == session && response.Sequence == sequence) return (response, discarded);
            if (discarded >= MaximumStale) throw new InvalidDataException("The speech engine sent live results for another window.");
        }
    }

    public static async Task<Response> ReadResponse(Stream input, CancellationToken cancel)
    {
        var header = new byte[16];
        await input.ReadExactlyAsync(header, cancel);
        uint kind = BinaryPrimitives.ReadUInt32LittleEndian(header), version = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
        uint session = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8)), sequence = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
        if (kind is not (Result or Error)) throw new InvalidDataException("The speech engine sent an invalid live response.");
        if (version != Version) throw new InvalidDataException("The speech engine uses a different live protocol version. Install a complete pFlow package.");
        if (kind == Error) return new(session, sequence, null, await Text(input, MaximumText, cancel), 0);
        uint count = await Number(input, cancel);
        if (count > MaximumSegments) throw new InvalidDataException("The speech engine sent too many live segments.");
        var segments = new List<WhisperWindowSegment>((int)count);
        int total = 0;
        var fixedPart = new byte[12];
        for (int index = 0; index < count; index++) {
            await input.ReadExactlyAsync(fixedPart, cancel);
            int from = BinaryPrimitives.ReadInt32LittleEndian(fixedPart), to = BinaryPrimitives.ReadInt32LittleEndian(fixedPart.AsSpan(4));
            float noSpeech = BinaryPrimitives.ReadSingleLittleEndian(fixedPart.AsSpan(8));
            if (!float.IsFinite(noSpeech)) throw new InvalidDataException("The speech engine sent an invalid live segment.");
            string text = await Text(input, MaximumText, cancel);
            total += text.Length;
            if (total > MaximumTotalText) throw new InvalidDataException("The speech engine sent too much live text.");
            segments.Add(new(from, to, text, noSpeech));
        }
        var milliseconds = new byte[8];
        await input.ReadExactlyAsync(milliseconds, cancel);
        return new(session, sequence, segments, null, BinaryPrimitives.ReadDoubleLittleEndian(milliseconds));
    }

    static async Task<uint> Number(Stream input, CancellationToken cancel)
    {
        var bytes = new byte[4];
        await input.ReadExactlyAsync(bytes, cancel);
        return BinaryPrimitives.ReadUInt32LittleEndian(bytes);
    }

    static async Task<string> Text(Stream input, int maximum, CancellationToken cancel)
    {
        uint length = await Number(input, cancel);
        if (length > maximum) throw new InvalidDataException("The speech engine sent an oversized live text.");
        var bytes = new byte[length];
        await input.ReadExactlyAsync(bytes, cancel);
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { throw new InvalidDataException("The speech engine sent live text that is not UTF-8."); }
    }
}
