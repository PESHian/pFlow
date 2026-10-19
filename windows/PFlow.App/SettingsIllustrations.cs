namespace PFlow.Windows;

internal abstract class PeshDrawing : FrameworkElement
{
    public static readonly DependencyProperty InkProperty = DependencyProperty.Register(nameof(Ink), typeof(Brush), typeof(PeshDrawing), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }
    protected PeshDrawing() { Focusable = false; IsHitTestVisible = false; SetResourceReference(InkProperty, "PeshGradient"); }
    protected Brush CanvasInk(double width, double height)
    {
        if (Ink is not LinearGradientBrush gradient) return Ink;
        var ink = gradient.CloneCurrentValue();
        ink.MappingMode = BrushMappingMode.Absolute;
        ink.StartPoint = new Point(gradient.StartPoint.X * width, gradient.StartPoint.Y * height);
        ink.EndPoint = new Point(gradient.EndPoint.X * width, gradient.EndPoint.Y * height);
        return ink;
    }
}

// The Mac preview samples and colors, drawn at the current Windows display scale.
internal sealed class WaveformPreview(string style) : PeshDrawing
{
    static readonly double[] levels = [.02, .05, .12, .24, .38, .24, .14, .07, .16, .29, .46, .33, .20, .10, .16, .28, .40, .29, .16, .08, .13, .23, .15, .07, .02];
    protected override void OnRender(DrawingContext dc)
    {
        double width = ActualWidth, mid = ActualHeight / 2;
        if (width <= 0 || mid <= 0) return;
        var ink = CanvasInk(width, ActualHeight);
        double[] samples = width < 40 ? [.16, .55, .95, .65, .9, .35] : levels;
        double step = width / samples.Length;
        double amplitude(double value) => Math.Pow(Math.Clamp(value / Math.Max(.25, samples.Max()), 0, 1), 1.6) * mid * .9;
        if (style == "lines") {
            var pen = new Pen(ink, Math.Min(2, step * .6)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
            for (int i = 0; i < samples.Length; i++) { double x = (i + .5) * step, height = Math.Max(.6, amplitude(samples[i])); dc.DrawLine(pen, new Point(x, mid - height), new Point(x, mid + height)); }
            return;
        }
        var points = samples.Select((value, i) => new Point((i + .5) * step, mid - amplitude(value))).ToArray();
        var shape = new StreamGeometry();
        using (var path = shape.Open()) {
            path.BeginFigure(new Point(0, mid), true, true);
            for (int i = 0; i < points.Length; i++) { var next = i + 1 < points.Length ? points[i + 1] : new Point(width, mid); path.QuadraticBezierTo(points[i], new Point((points[i].X + next.X) / 2, (points[i].Y + next.Y) / 2), true, false); }
            path.LineTo(new Point(width, mid), true, false);
            for (int i = points.Length - 1; i >= 0; i--) { var point = new Point(points[i].X, 2 * mid - points[i].Y); var next = i > 0 ? new Point(points[i - 1].X, 2 * mid - points[i - 1].Y) : new Point(0, mid); path.QuadraticBezierTo(point, new Point((point.X + next.X) / 2, (point.Y + next.Y) / 2), true, false); }
        }
        dc.DrawGeometry(ink, new Pen(new SolidColorBrush(Color.FromArgb(128, 0, 0, 0)), .75), shape);
    }
}

internal sealed class NavigationGlyph(string kind) : PeshDrawing
{
    protected override void OnRender(DrawingContext dc)
    {
        dc.PushTransform(new ScaleTransform(ActualWidth / 24, ActualHeight / 24));
        var ink = CanvasInk(24, 24);
        var pen = new Pen(ink, 1.5) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        switch (kind) {
            case "Templates":
                dc.DrawGeometry(null, pen, Geometry.Parse("M 5,2 L 14,2 20,8 20,21 Q 20,23 18,23 L 5,23 Q 3,23 3,21 L 3,4 Q 3,2 5,2 M 13,2 L 13,9 20,9 M 7,13 L 16,13 M 7,17 L 16,17")); break;
            case "Usage statistics":
                dc.DrawRoundedRectangle(ink, null, new Rect(2, 11, 5, 12), 1.5, 1.5); dc.DrawRoundedRectangle(ink, null, new Rect(9, 6, 5, 17), 1.5, 1.5); dc.DrawRoundedRectangle(ink, null, new Rect(16, 2, 5, 21), 1.5, 1.5); break;
            case "View history":
                pen.Brush = (Brush)FindResource("PeshMuted"); dc.DrawGeometry(null, pen, Geometry.Parse("M 3,12 A 9,9 0 1 1 7,20 M 0,9 L 3,13 6,9 M 12,6 L 12,12 16,15")); break;
            default:
                pen.Brush = (Brush)FindResource("PeshMuted"); dc.DrawGeometry(null, pen, Geometry.Parse("M 5,2 L 19,2 19,21 5,21 Q 2,21 2,18 L 2,5 Q 2,2 5,2 M 5,2 L 5,21 M 8,15 L 11,6 14,15 M 9,12 L 13,12 M 8,18 L 16,18")); break;
        }
        dc.Pop();
    }
}
