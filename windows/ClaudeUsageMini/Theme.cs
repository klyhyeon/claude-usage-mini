using System.Windows.Media;

namespace ClaudeUsageMini;

/// <summary>Fixed dark palette from the agreed mockup — deliberately one look,
/// not theme-following, so it matches the macOS app.</summary>
public static class Theme
{
    public static readonly Brush Panel = Frozen(40, 40, 40);
    public static readonly Brush Card = Frozen(51, 51, 51);
    public static readonly Brush CardBorder = Frozen(255, 255, 255, 16);
    public static readonly Brush Title = Frozen(255, 255, 255);
    public static readonly Brush Dim = Frozen(160, 160, 160);
    public static readonly Brush Faint = Frozen(122, 122, 122);
    public static readonly Brush Track = Frozen(255, 255, 255, 31);
    public static readonly Brush BadgeBg = Frozen(255, 255, 255, 26);
    public static readonly Brush Green = Frozen(108, 203, 95);
    public static readonly Brush Orange = Frozen(232, 150, 60);
    public static readonly Brush Red = Frozen(230, 90, 90);

    /// <summary>Green under 70, amber to 90, red past it — a glanceable ramp.</summary>
    public static Brush Ramp(double percent) => percent switch
    {
        < 70 => Green,
        < 90 => Orange,
        _ => Red,
    };

    public static System.Drawing.Color RampColor(double percent) => percent switch
    {
        < 70 => System.Drawing.Color.FromArgb(108, 203, 95),
        < 90 => System.Drawing.Color.FromArgb(232, 150, 60),
        _ => System.Drawing.Color.FromArgb(230, 90, 90),
    };

    private static Brush Frozen(byte r, byte g, byte b, byte a = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }
}
