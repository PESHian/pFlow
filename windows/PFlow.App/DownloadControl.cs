using System.Windows;
using System.Windows.Controls;

namespace PFlow.Windows;

internal static class FileSize
{
    /// "1.1 GB" from a gigabyte up, "488 MB" below, as the download buttons have always said.
    public static string Describe(long bytes) => bytes >= 1_000_000_000 ? (bytes / 1e9).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " GB" : Math.Round(bytes / 1e6).ToString(System.Globalization.CultureInfo.InvariantCulture) + " MB";
}

internal enum DownloadState { Ready, Downloading, Installed, Failed }

/// One download control, the same for every model file: before, one "Download (size)" button;
/// while downloading, a bar, "Downloading… 120 MB of 1.1 GB" and one Cancel; after, "Downloaded ·
/// size" and nothing to press; after a failure, its plain line and the Download button again.
/// Nothing is shown that cannot be acted on right now, and everything sits under its own button.
internal sealed class DownloadControl : StackPanel
{
    public readonly record struct Look(string? Button, bool Progress, bool Cancel, string Line);
    /// The rule, by state. `note` is the failure's reason, or a line to show beside the Download button.
    public static Look Describe(DownloadState state, long total, long received, string? note) => state switch {
        DownloadState.Downloading => new(null, true, true, $"Downloading… {FileSize.Describe(received)} of {FileSize.Describe(total)}"),
        DownloadState.Installed => new(null, false, false, $"Downloaded · {FileSize.Describe(total)}"),
        DownloadState.Failed => new($"Download ({FileSize.Describe(total)})", false, false, note ?? "The download did not finish."),
        _ => new($"Download ({FileSize.Describe(total)})", false, false, note ?? ""),
    };
    readonly Button download, cancel;
    readonly ProgressBar bar = new() { Minimum = 0, Maximum = 1, Height = 5, Margin = new Thickness(0, 6, 0, 2) };
    readonly TextBlock line = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 1, 0, 1) };
    readonly long total;
    readonly Func<bool> installed;
    readonly Func<IProgress<double>, CancellationToken, Task> fetch;
    readonly Func<string?> blocked;
    readonly Action? done;
    CancellationTokenSource? running;
    public DownloadState State { get; private set; }
    /// `installed` says whether the file is on this PC; `fetch` downloads it with progress as a
    /// fraction; `blocked` names why a download cannot start right now (dictation in progress), or null.
    public DownloadControl(string name, long total, Func<bool> installed, Func<IProgress<double>, CancellationToken, Task> fetch, Func<string?> blocked, Action? done = null)
    {
        this.total = total; this.installed = installed; this.fetch = fetch; this.blocked = blocked; this.done = done;
        System.Windows.Automation.AutomationProperties.SetName(this, name + " download");
        download = new Button { Margin = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Left }; download.Click += (_, _) => Start();
        cancel = new Button { Content = "Cancel", Margin = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Left }; cancel.Click += (_, _) => Cancel();
        System.Windows.Automation.AutomationProperties.SetName(bar, name + " download progress");
        Children.Add(download); Children.Add(bar); Children.Add(line); Children.Add(cancel);
        Show(installed() ? DownloadState.Installed : DownloadState.Ready);
    }
    internal void Show(DownloadState state, long received = 0, string? note = null)
    {
        var look = Describe(state, total, received, note); State = state;
        download.Content = look.Button; download.Visibility = look.Button != null ? Visibility.Visible : Visibility.Collapsed;
        bar.Value = total > 0 ? (double)received / total : 0; bar.Visibility = look.Progress ? Visibility.Visible : Visibility.Collapsed;
        cancel.Visibility = look.Cancel ? Visibility.Visible : Visibility.Collapsed;
        line.Text = look.Line; line.Visibility = look.Line.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    async void Start()
    {
        if (running != null) return;
        if (blocked() is { } why) { Show(State, note: why); return; }
        running = new CancellationTokenSource(); Show(DownloadState.Downloading);
        try {
            await fetch(new DispatcherProgress(this, fraction => { if (State == DownloadState.Downloading) Show(DownloadState.Downloading, (long)(Math.Clamp(fraction, 0, 1) * total)); }), running.Token);
            Show(installed() ? DownloadState.Installed : DownloadState.Failed, note: "The file is not where pFlow expected it.");
        }
        catch (OperationCanceledException) { Show(DownloadState.Ready, note: "Download canceled."); }
        catch (Exception error) { Show(DownloadState.Failed, note: error.Message); }
        finally { running.Dispose(); running = null; done?.Invoke(); }
    }
    public void Cancel() => running?.Cancel();
    /// Progress reported from the download thread, applied on this control's own thread.
    sealed class DispatcherProgress(DownloadControl control, Action<double> apply) : IProgress<double>
    {
        public void Report(double value) => control.Dispatcher.BeginInvoke(apply, value);
    }
}
