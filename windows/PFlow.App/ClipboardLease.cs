using System.Text;

namespace PFlow.Windows;

// Every read/change/restore is under the Windows clipboard lock. Sequence comparison is atomic with restoration.
internal sealed class ClipboardLease : IDisposable
{
    internal static readonly List<ClipboardLease> Pending = [];
    readonly List<(uint Format, IntPtr Handle)> original = [];
    readonly IntPtr owner;
    uint installedSequence;
    internal uint InstalledSequence => installedSequence;
    bool installed, restored;
    readonly bool preserve;
    uint sourceSequence;
    public ClipboardLease(IntPtr owner, bool preserve)
    {
        this.owner = owner; this.preserve = preserve;
        if (!preserve) return;
        Open();
        try {
            uint format = 0; long total = 0;
            while ((format = Native.EnumClipboardFormats(format)) != 0) {
                IntPtr value = Native.GetClipboardData(format), clone;
                if (value == IntPtr.Zero) {
                    // Windows advertises a synthesized bitmap for a DIB. A private desktop may not rasterize it;
                    // retaining the complete source DIB lets Windows synthesize that format again on restoration.
                    if (format == 2 && original.Any(x => x.Format is 8 or 17)) continue;
                    int error = Marshal.GetLastWin32Error(); var name = new StringBuilder(256); Native.GetClipboardFormatName(format, name, name.Capacity);
                    throw new InvalidOperationException("The clipboard could not be saved. Your text is in History.") { Data = { ["ClipboardFormat"] = format, ["FormatName"] = name.ToString(), ["Win32Error"] = error } };
                }
                if (format == 2) clone = Native.CopyImage(value, 0, 0, 0, 0x2000);
                else if (format == 14) clone = Native.CopyEnhMetaFile(value, null);
                else {
                    if (format is 3 or 9 or 0x80 or 0x82 or 0x83 or 0x8E) throw new InvalidOperationException("This clipboard format cannot be restored safely. Your text is in History.");
                    long length = (long)Native.GlobalSize(value).ToUInt64(); total += length;
                    if (length <= 0 || total > 512L * 1024 * 1024) throw new InvalidOperationException("The clipboard is too large to save safely. Your text is in History.");
                    var bytes = new byte[length]; var pointer = Native.GlobalLock(value);
                    if (pointer == IntPtr.Zero) throw new InvalidOperationException("The clipboard is busy. Your text is in History.");
                    try { Marshal.Copy(pointer, bytes, 0, bytes.Length); } finally { Native.GlobalUnlock(value); }
                    clone = Allocate(bytes);
                }
                if (clone == IntPtr.Zero) throw new InvalidOperationException("The clipboard could not be saved. Your text is in History.");
                original.Add((format, clone));
            }
            sourceSequence = Native.GetClipboardSequenceNumber();
        } catch { Dispose(); throw; }
        finally { Native.CloseClipboard(); }
    }
    /// Clipboard history, sync tools and remote-desktop helpers open the clipboard for a moment after every
    /// change: a busy clipboard gets up to half a second before the take gives up.
    void Open()
    {
        for (int attempt = 0; !Native.OpenClipboard(owner); attempt++) {
            if (attempt >= 20) throw new InvalidOperationException("The clipboard is busy. Your text is in History.");
            Thread.Sleep(25);
        }
    }
    static IntPtr Allocate(byte[] bytes)
    {
        var handle = Native.GlobalAlloc(2, (UIntPtr)bytes.Length);
        if (handle == IntPtr.Zero) throw new OutOfMemoryException();
        var pointer = Native.GlobalLock(handle);
        if (pointer == IntPtr.Zero) { Native.GlobalFree(handle); throw new OutOfMemoryException(); }
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); } finally { Native.GlobalUnlock(handle); }
        return handle;
    }
    public void Put(string text, string? rtf = null)
    {
        var incoming = new List<(uint Format, IntPtr Handle)>();
        try {
            incoming.Add((13, Allocate(Encoding.Unicode.GetBytes(text + "\0"))));
            // Materialize Windows' synthesized text formats now, so reads/CloseClipboard cannot advance our ownership sequence.
            incoming.Add((1, Allocate(CodePageText(text, 0))));
            incoming.Add((7, Allocate(CodePageText(text, 1))));
            incoming.Add((16, Allocate(BitConverter.GetBytes(Native.GetSystemDefaultLCID()))));
            if (rtf != null) incoming.Add((Native.RegisterClipboardFormat("Rich Text Format"), Allocate(Encoding.ASCII.GetBytes(rtf + "\0"))));
            foreach (var (name, data) in Private) incoming.Add((Native.RegisterClipboardFormat(name), Allocate(data)));
            Open();
            try {
                if (preserve && Native.GetClipboardSequenceNumber() != sourceSequence) throw new InvalidOperationException("The clipboard changed. Your text is in History.");
                if (!Native.EmptyClipboard()) throw new InvalidOperationException("Windows blocked the clipboard.");
                installed = true;
                for (int i = 0; i < incoming.Count; i++) {
                    var item = incoming[i];
                    if (Native.SetClipboardData(item.Format, item.Handle) == IntPtr.Zero) throw new InvalidOperationException("Windows blocked the clipboard.");
                    incoming[i] = (item.Format, IntPtr.Zero);
                }
            } finally { installedSequence = Native.GetClipboardSequenceNumber(); Native.CloseClipboard(); }
        } finally { foreach (var item in incoming) Free(item.Format, item.Handle); }
    }
    /// Every pFlow write (the words it pastes, the card's Copy, "Copy dictation to clipboard") is private:
    /// Windows' clipboard history (Win+V) and cloud clipboard leave it out. The person's own clipboard,
    /// put back by Restore, goes back exactly as it was, without these. Windows refuses an empty clipboard
    /// item, so the first (whose presence is what counts: "any data") carries a DWORD 0 like the others.
    internal static readonly (string Name, byte[] Data)[] Private = [
        ("ExcludeClipboardContentFromMonitorProcessing", BitConverter.GetBytes(0)),
        ("CanIncludeInClipboardHistory", BitConverter.GetBytes(0)),
        ("CanUploadToCloudClipboard", BitConverter.GetBytes(0)),
    ];
    static byte[] CodePageText(string text, uint codePage)
    {
        int count = Native.WideCharToMultiByte(codePage, 0, text, -1, null, 0, IntPtr.Zero, IntPtr.Zero);
        if (count <= 0) throw new InvalidOperationException("Windows could not prepare the text clipboard.");
        var bytes = new byte[count];
        if (Native.WideCharToMultiByte(codePage, 0, text, -1, bytes, count, IntPtr.Zero, IntPtr.Zero) != count) throw new InvalidOperationException("Windows could not prepare the text clipboard.");
        return bytes;
    }
    public bool Restore()
    {
        if (!installed || restored) return true;
        if (!Native.OpenClipboard(owner)) return false;
        try {
            if (Native.GetClipboardSequenceNumber() != installedSequence) { restored = true; return true; }
            var copies = new List<(uint Format, IntPtr Handle)>();
            try { foreach (var item in original) copies.Add((item.Format, Clone(item.Format, item.Handle))); }
            catch { foreach (var item in copies) Free(item.Format, item.Handle); return false; }
            if (!Native.EmptyClipboard()) { foreach (var item in copies) Free(item.Format, item.Handle); return false; }
            bool success = true;
            foreach (var item in copies) {
                if (Native.SetClipboardData(item.Format, item.Handle) == IntPtr.Zero) { Free(item.Format, item.Handle); success = false; }
            }
            installedSequence = Native.GetClipboardSequenceNumber();
            restored = success;
            return success;
        } finally { Native.CloseClipboard(); }
    }
    public void Keep() => restored = true;
    /// "Copy dictation to clipboard" after the text already went in another way:
    /// the copy stays, and nothing is restored over it.
    internal static void KeepCopy(IntPtr owner, string text)
    {
        using var lease = new ClipboardLease(owner, false);
        lease.Put(text); lease.Keep();
    }
    /// Ctrl+V, right after the caller's last checks: nothing here waits. The clipboard is not opened (another
    /// program holding it, such as clipboard history right after Put, would make this wait after the focus
    /// checks); the sequence number, readable without the lock, says the clipboard still holds pFlow's words.
    public void DispatchPaste()
    {
        if (!installed || Native.GetClipboardSequenceNumber() != installedSequence)
            throw new InvalidOperationException("The clipboard changed before insertion. Your text is in History.");
        SendKeys([Native.Key(0x11), Native.Key(0x56), Native.Key(0x56, true), Native.Key(0x11, true)]);
    }
    /// SendInput; the native checks record the keys instead (their private desktop must not send Ctrl+V anywhere).
    internal static Action<Native.Input[]> SendKeys { get; set; } = inputs => Native.Send(inputs);
    static IntPtr Clone(uint format, IntPtr handle)
    {
        IntPtr result;
        if (format == 2) result = Native.CopyImage(handle, 0, 0, 0, 0x2000);
        else if (format == 14) result = Native.CopyEnhMetaFile(handle, null);
        else {
            int length = checked((int)Native.GlobalSize(handle).ToUInt64()); var bytes = new byte[length];
            var pointer = Native.GlobalLock(handle);
            if (pointer == IntPtr.Zero) throw new IOException("The saved clipboard could not be read.");
            try { Marshal.Copy(pointer, bytes, 0, length); } finally { Native.GlobalUnlock(handle); }
            result = Allocate(bytes);
        }
        return result != IntPtr.Zero ? result : throw new OutOfMemoryException();
    }
    static void Free(uint format, IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        if (format == 2) Native.DeleteObject(handle);
        else if (format == 14) Native.DeleteEnhMetaFile(handle);
        else Native.GlobalFree(handle);
    }
    internal static void RestorePending()
    {
        foreach (var lease in Pending.ToArray()) if (lease.Restore()) { Pending.Remove(lease); lease.Dispose(); }
    }
    public void Dispose()
    {
        if (preserve && installed && !restored) { if (!Pending.Contains(this)) Pending.Add(this); return; }
        foreach (var item in original) Free(item.Format, item.Handle);
        original.Clear();
    }
}
