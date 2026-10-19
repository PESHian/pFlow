namespace PFlow.Windows;

internal sealed class WaveRecorder : IDisposable
{
    [StructLayout(LayoutKind.Sequential, Pack = 2)] struct Format { public ushort Tag, Channels; public uint Rate, BytesPerSecond; public ushort Align, Bits, Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Header { public IntPtr Data; public uint Length, Recorded; public UIntPtr User; public uint Flags, Loops; public IntPtr Next; public UIntPtr Reserved; }
    delegate void WaveCallback(IntPtr input, uint message, UIntPtr instance, IntPtr param1, IntPtr param2);
    [DllImport("winmm.dll")] static extern uint waveInOpen(out IntPtr input, uint device, ref Format format, WaveCallback callback, UIntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveInPrepareHeader(IntPtr input, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInUnprepareHeader(IntPtr input, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInAddBuffer(IntPtr input, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInStart(IntPtr input);
    [DllImport("winmm.dll")] static extern uint waveInReset(IntPtr input);
    [DllImport("winmm.dll")] static extern uint waveInClose(IntPtr input);
    [DllImport("winmm.dll")] internal static extern uint waveInGetNumDevs();
    readonly WaveCallback callback;
    readonly List<(IntPtr Header, IntPtr Buffer)> buffers = [];
    readonly object sync = new();
    readonly System.Collections.Concurrent.ConcurrentQueue<IntPtr> completed = new();
    readonly AutoResetEvent dataReady = new(false);
    Thread? worker;
    int outstanding;
    readonly FileStream file;
    IntPtr input;
    volatile bool stopping;
    bool disposed;
    Exception? failure;
    public double Level { get; private set; }
    public double DurationSeconds => Math.Max(0, (file.Length - 44) / 32000.0);
    public string Path { get; }
    public WaveRecorder(string path)
    {
        Path = path; file = new(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None); file.Write(new byte[44]);
        callback = Receive;
        var format = new Format { Tag = 1, Channels = 1, Rate = 16000, BytesPerSecond = 32000, Align = 2, Bits = 16 };
        try {
            Check(waveInOpen(out input, uint.MaxValue, ref format, callback, UIntPtr.Zero, 0x30000));
            for (int i = 0; i < 4; i++) {
                var data = Marshal.AllocHGlobal(3200); var header = Marshal.AllocHGlobal(Marshal.SizeOf<Header>());
                Marshal.StructureToPtr(new Header { Data = data, Length = 3200 }, header, false);
                buffers.Add((header, data)); Check(waveInPrepareHeader(input, header, (uint)Marshal.SizeOf<Header>()));
                Interlocked.Increment(ref outstanding);
                uint result = waveInAddBuffer(input, header, (uint)Marshal.SizeOf<Header>());
                if (result != 0) Interlocked.Decrement(ref outstanding);
                Check(result);
            }
            worker = new Thread(Consume) { IsBackground = true, Name = "pFlow microphone writer" }; worker.Start();
            Check(waveInStart(input));
        } catch { Dispose(); throw; }
    }
    static void Check(uint code) { if (code != 0) throw new InvalidOperationException($"Microphone could not start (Windows audio error {code}). Check Windows microphone access."); }
    void Receive(IntPtr handle, uint message, UIntPtr instance, IntPtr p1, IntPtr p2)
    {
        if (message != 0x3C0) return;
        // Wave callbacks may signal work. Audio/file APIs run only on the worker.
        completed.Enqueue(p1); dataReady.Set();
    }
    void Consume()
    {
        while (!stopping || Volatile.Read(ref outstanding) > 0) {
            if (!completed.TryDequeue(out var pointer)) { dataReady.WaitOne(100); continue; }
            try {
                var header = Marshal.PtrToStructure<Header>(pointer);
                if (header.Recorded > 0) {
                    var bytes = new byte[header.Recorded]; Marshal.Copy(header.Data, bytes, 0, bytes.Length); file.Write(bytes);
                    double sum = 0; for (int i = 0; i + 1 < bytes.Length; i += 2) { double v = BitConverter.ToInt16(bytes, i) / 32768.0; sum += v * v; }
                    double rms = Math.Sqrt(sum / Math.Max(1, bytes.Length / 2));
                    Level = rms <= 0 ? 0 : Math.Pow(Math.Clamp((20 * Math.Log10(rms) + 45) / 45, 0, 1), 1.5);
                }
                lock (sync) {
                    if (!stopping) {
                        Interlocked.Increment(ref outstanding);
                        uint result = waveInAddBuffer(input, pointer, (uint)Marshal.SizeOf<Header>());
                        if (result != 0) Interlocked.Decrement(ref outstanding);
                        Check(result);
                    }
                }
            } catch (Exception error) { failure = error; stopping = true; }
            finally { Interlocked.Decrement(ref outstanding); }
        }
    }
    void Drain()
    {
        lock (sync) stopping = true;
        if (input != IntPtr.Zero) waveInReset(input);
        dataReady.Set();
        if (worker != null && !worker.Join(5000)) throw new IOException("The microphone is still stopping. Keep pFlow open.");
    }
    public double Stop()
    {
        if (disposed) return 0;
        Drain();
        lock (sync) {
            double seconds = DurationSeconds; long length = file.Length - 44;
            file.Position = 0;
            using (var writer = new BinaryWriter(file, System.Text.Encoding.ASCII, true)) {
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); writer.Write((uint)(length + 36)); writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write(16u); writer.Write((ushort)1); writer.Write((ushort)1); writer.Write(16000u); writer.Write(32000u); writer.Write((ushort)2); writer.Write((ushort)16);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data")); writer.Write((uint)length); writer.Flush();
            }
            file.Flush(true);
            Dispose(); if (failure != null) throw new IOException("Microphone capture stopped. Please try again.", failure);
            return seconds;
        }
    }
    public void Dispose()
    {
        if (disposed) return; Drain();
        if (input != IntPtr.Zero) {
            foreach (var b in buffers) waveInUnprepareHeader(input, b.Header, (uint)Marshal.SizeOf<Header>());
            waveInClose(input); input = IntPtr.Zero;
        }
        foreach (var b in buffers) { Marshal.FreeHGlobal(b.Header); Marshal.FreeHGlobal(b.Buffer); }
        buffers.Clear(); file.Dispose(); dataReady.Dispose(); disposed = true;
    }
}
