namespace PFlow.Windows;

/// AI cleanup that could not be used is said in a balloon once per app start; after that the
/// Settings processing line and the History status carry it (a balloon on every take was noise).
/// Every other notice is always shown.
internal sealed class CleanupNotice
{
    bool shown;
    public bool Allow(bool cleanup)
    {
        if (!cleanup) return true;
        if (shown) return false;
        shown = true; return true;
    }
}
