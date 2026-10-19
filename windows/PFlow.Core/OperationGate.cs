namespace PFlow.Core;

// Cancellation asks an operation to stop. Its ownership lasts until its asynchronous cleanup completes.
public sealed class OperationGate
{
    long serial, active;
    public bool Busy => active != 0;
    public long Start()
    {
        if (Busy) throw new InvalidOperationException("The previous dictation is still stopping.");
        return active = ++serial;
    }
    public bool Complete(long owner)
    {
        if (owner == 0 || active != owner) return false;
        active = 0; return true;
    }
}
public sealed record FieldState(long Window, uint Process, string Element, string Text, int Start, int Length, bool Secure = false)
{
    public static void RequireUnchanged(FieldState original, FieldState current)
    {
        if (original.Secure || current.Secure) throw new InvalidOperationException("Dictation is off in password fields.");
        if (original.Window != current.Window || original.Process != current.Process || original.Element != current.Element)
            throw new InvalidOperationException("Focus changed. Your text is in History.");
        if (original.Text != current.Text || original.Start != current.Start || original.Length != current.Length)
            throw new InvalidOperationException("The field changed. Your text is in History.");
    }
    public string Inserted(string text)
    {
        if (Secure || Start < 0 || Length < 0 || Start > Text.Length || Length > Text.Length - Start)
            throw new InvalidOperationException("The text selection could not be checked. Your text is in History.");
        return Text[..Start] + text + Text[(Start + Length)..];
    }
}
