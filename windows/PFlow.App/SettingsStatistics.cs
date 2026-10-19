using System.Globalization;
using System.Windows.Automation;

namespace PFlow.Windows;

internal sealed partial class SettingsWindow
{
    internal static string UsageTime(Usage usage)
    {
        if (usage.Seconds <= 0) return "—";
        long seconds = (long)usage.Seconds;
        return seconds < 60 ? $"{seconds}s" : seconds < 3600 ? $"{seconds / 60}m {seconds % 60}s" : $"{seconds / 3600}h {seconds % 3600 / 60}m";
    }
    static string Pace(Usage usage) => usage.Seconds > 0 ? usage.WordsPerMinute.ToString("N0") : "—";
    static TextBlock StatisticsText(string text, double size = 12, bool muted = false)
    {
        var block = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap };
        block.SetResourceReference(TextBlock.ForegroundProperty, muted ? "PeshMuted" : "PeshText");
        return block;
    }
    static TextBlock StatisticsHeading(string text)
    {
        var heading = StatisticsText(text, 10, true); heading.FontFamily = new FontFamily("Consolas");
        heading.Margin = new Thickness(0, 24, 0, 14); return heading;
    }
    UIElement Statistics()
    {
        var stats = UsageStatistics.From(store.History, DateOnly.FromDateTime(DateTime.Today));
        var root = Panel(); root.Margin = new Thickness(20, 22, 20, 20);
        var totals = new Grid { Margin = new Thickness(0, 0, 0, 1) };
        var values = new[] { ("Words dictated", stats.Total.Words.ToString("N0")), ("Dictations", stats.Total.Dictations.ToString("N0")), ("Time tracked", UsageTime(stats.Total)), ("WPM tracked", Pace(stats.Total)) };
        for (int i = 0; i < values.Length; i++) {
            totals.ColumnDefinitions.Add(new ColumnDefinition());
            var stack = new StackPanel { Margin = new Thickness(0, 0, i == 3 ? 0 : 8, 0) };
            var number = StatisticsText(values[i].Item2, 21); number.FontWeight = FontWeights.SemiBold; number.TextWrapping = TextWrapping.NoWrap;
            number.TextTrimming = TextTrimming.CharacterEllipsis; number.ToolTip = values[i].Item2;
            AutomationProperties.SetName(number, values[i].Item1 + ": " + values[i].Item2);
            var caption = StatisticsText(values[i].Item1, 10, true); caption.Margin = new Thickness(0, 5, 0, 0);
            stack.Children.Add(number); stack.Children.Add(caption); Grid.SetColumn(stack, i); totals.Children.Add(stack);
        }
        root.Children.Add(totals);
        root.Children.Add(StatisticsHeading("D A I L Y  A C T I V I T Y"));
        root.Children.Add(new UsageChart(stats.RecentDays) { Height = 160 });
        var captionText = StatisticsText("Last 7 calendar days · words per day", 10, true); captionText.Margin = new Thickness(0, 14, 0, 20); root.Children.Add(captionText);
        string timing = stats.Total.Seconds <= 0 ? "Speaking pace will appear when dictations have recorded timing. Earlier word totals have no reliable timing."
            : stats.Total.TimedWords < stats.Total.Words ? $"Speaking pace uses {stats.Total.TimedWords:N0} words with recorded timing. Earlier word totals have no reliable timing."
            : "Speaking pace uses recorded dictation time, including pauses.";
        var timingText = StatisticsText(timing, 10, true); timingText.LineHeight = 16; timingText.Margin = new Thickness(0, 0, 0, 18); root.Children.Add(timingText);
        root.Children.Add(UsageTable(stats.ActiveDays.Select(x => (x.Date.ToString("MMM d, yyyy"), x.Totals)), "Daily usage"));
        var daysCaption = StatisticsText("Most recent 30 active days", 10, true); daysCaption.Margin = new Thickness(0, 12, 0, 0); root.Children.Add(daysCaption);
        root.Children.Add(StatisticsHeading("B Y  A P P  ·  A L L  T I M E"));
        root.Children.Add(UsageTable(stats.Applications.Select(x => (x.Name, x.Totals)), "Usage by app"));
        var footnote = StatisticsText("Statistics come from saved history on this PC. Deleting a dictation removes it from these totals.", 10, true);
        footnote.Margin = new Thickness(0, 22, 0, 0); footnote.LineHeight = 16; root.Children.Add(footnote);
        return root;
    }
    static Grid UsageTable(IEnumerable<(string Name, Usage Totals)> entries, string name)
    {
        var table = new Grid(); AutomationProperties.SetName(table, name);
        // Same right edges in both tables; only the name column grows with the window.
        table.ColumnDefinitions.Add(new ColumnDefinition());
        foreach (double width in new[] { 65.0, 75, 50 }) table.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width) });
        void Cell(int row, int column, string value, bool heading = false) {
            var text = StatisticsText(value, heading ? 10 : 12, heading); text.Margin = new Thickness(0, heading ? 0 : 10, 0, heading ? 10 : 6);
            if (column > 0) { text.TextAlignment = TextAlignment.Right; text.TextWrapping = TextWrapping.NoWrap; System.Windows.Documents.Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular); }
            else text.Margin = new Thickness(0, heading ? 0 : 10, 8, heading ? 10 : 6);
            Grid.SetRow(text, row); Grid.SetColumn(text, column); table.Children.Add(text);
        }
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var headers = new[] { "Day / app", "Words", "Time", "WPM" }; for (int i = 0; i < 4; i++) Cell(0, i, headers[i], true);
        int row = 1;
        foreach (var (label, usage) in entries) {
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Cell(row, 0, label); Cell(row, 1, usage.Words.ToString("N0")); Cell(row, 2, UsageTime(usage)); Cell(row, 3, Pace(usage)); row++;
        }
        if (row == 1) { table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); Cell(1, 0, "No dictations yet."); }
        return table;
    }
}

internal sealed class UsageChart : FrameworkElement
{
    readonly IReadOnlyList<DailyUsage> days;
    public static readonly DependencyProperty InkProperty = DependencyProperty.Register(nameof(Ink), typeof(Brush), typeof(UsageChart), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty LabelInkProperty = DependencyProperty.Register(nameof(LabelInk), typeof(Brush), typeof(UsageChart), new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty GridInkProperty = DependencyProperty.Register(nameof(GridInk), typeof(Brush), typeof(UsageChart), new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }
    public Brush LabelInk { get => (Brush)GetValue(LabelInkProperty); set => SetValue(LabelInkProperty, value); }
    public Brush GridInk { get => (Brush)GetValue(GridInkProperty); set => SetValue(GridInkProperty, value); }
    public UsageChart(IReadOnlyList<DailyUsage> days)
    {
        this.days = days;
        SetResourceReference(InkProperty, "PeshGradient"); SetResourceReference(LabelInkProperty, "PeshMuted"); SetResourceReference(GridInkProperty, "PeshBorder");
        string summary = "Daily activity. " + string.Join("; ", days.Select(x => $"{x.Date:MMM d}: {x.Totals.Words:N0} words"));
        AutomationProperties.SetName(this, summary); ToolTip = summary;
    }
    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => new System.Windows.Automation.Peers.FrameworkElementAutomationPeer(this);
    protected override void OnRender(DrawingContext dc)
    {
        if (days.Count == 0 || ActualWidth <= 80 || ActualHeight <= 50) return;
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        FormattedText Label(string text, double size = 10) => new(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), size, LabelInk, dpi);
        int max = days.Max(x => x.Totals.Words);
        double rawStep = Math.Max(1, max / 4.0), power = Math.Pow(10, Math.Floor(Math.Log10(rawStep)));
        double step = new[] { 1.0, 2, 5, 10 }.First(x => x * power >= rawStep) * power, top = step * 4;
        double left = Math.Max(34, Label(top.ToString("N0")).Width + 6), right = ActualWidth - 2, yTop = 20, bottom = ActualHeight - 24;
        for (int i = 0; i <= 4; i++) {
            double y = bottom - (bottom - yTop) * i / 4;
            dc.DrawLine(new Pen(GridInk, .75), new Point(left, y), new Point(right, y));
            var label = Label((step * i).ToString("N0")); dc.DrawText(label, new Point(left - label.Width - 5, y - label.Height / 2));
        }
        double slot = (right - left) / days.Count;
        Brush barInk = Ink;
        if (Ink is LinearGradientBrush gradient) { var vertical = gradient.CloneCurrentValue(); vertical.StartPoint = new Point(.25, 0); vertical.EndPoint = new Point(.75, 1); barInk = vertical; }
        for (int i = 0; i < days.Count; i++) {
            var day = days[i]; double x = left + slot * (i + .5);
            var date = Label(day.Date.ToString("MMM d"), 9); dc.DrawText(date, new Point(x - date.Width / 2, bottom + 5));
            if (day.Totals.Words <= 0) continue;
            double height = Math.Max(1, (bottom - yTop) * day.Totals.Words / top), width = Math.Min(20, slot * .5), y = bottom - height, radius = Math.Min(3, height / 2);
            var geometry = new StreamGeometry();
            using (var path = geometry.Open()) {
                path.BeginFigure(new Point(x - width / 2, bottom), true, true); path.LineTo(new Point(x - width / 2, y + radius), true, false);
                path.QuadraticBezierTo(new Point(x - width / 2, y), new Point(x - width / 2 + radius, y), true, false);
                path.LineTo(new Point(x + width / 2 - radius, y), true, false); path.QuadraticBezierTo(new Point(x + width / 2, y), new Point(x + width / 2, y + radius), true, false);
                path.LineTo(new Point(x + width / 2, bottom), true, false);
            }
            dc.DrawGeometry(barInk, null, geometry);
            var words = Label(day.Totals.Words.ToString("N0"), 10); dc.DrawText(words, new Point(x - words.Width / 2, y - words.Height - 4));
        }
    }
}
