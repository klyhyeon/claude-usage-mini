using System.Drawing;
using System.Drawing.Imaging;
using System.Windows;
using System.Windows.Forms;
using Application = System.Windows.Application;

namespace ClaudeUsageMini;

/// <summary>
/// Tray-only app: no main window, a NotifyIcon whose text is the usage label,
/// and a WPF flyout on click. Mirrors the macOS MenuBarExtra.
/// </summary>
public partial class App : Application
{
    private UsageModel _model = null!;
    private NotifyIcon _tray = null!;
    private PopupWindow _popup = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        LoginItem.EnableIfUnset();

        _model = new UsageModel();
        _popup = new PopupWindow(_model);

        _tray = new NotifyIcon
        {
            Visible = true,
            Icon = RenderIcon("—"),
            Text = "Claude Usage",
        };
        // A hidden click target so left-click reliably lands on our handler
        // rather than only surfacing the context menu.
        _tray.MouseClick += OnTrayClick;

        _model.Changed += OnModelChanged;
    }

    private void OnModelChanged()
    {
        _tray.Icon?.Dispose();
        _tray.Icon = RenderIcon(TrayGlyph());
        // NotifyIcon.Text (the hover tooltip) is capped at 63 chars — fine here.
        _tray.Text = $"Claude Usage · {_model.TrayLabel()}";
    }

    /// <summary>The tray slot is square, so only the session % fits legibly;
    /// the full "25%(4%) · 2:00pm" lives in the hover tooltip and the popup.</summary>
    private string TrayGlyph()
    {
        var session = _model.Usage?.Limits.FirstOrDefault(l => l.Id == "session")?.Percent;
        return session is { } pct ? $"{Math.Round(pct)}%" : "—";
    }

    private void OnTrayClick(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        var pos = Control.MousePosition;
        _popup.ToggleAt(pos.X, pos.Y);
    }

    /// <summary>
    /// The tray shows an icon, not text, so the label is drawn onto a bitmap.
    /// Session number takes the severity color; the rest stays light so it
    /// reads on the dark Windows taskbar.
    /// </summary>
    private Icon RenderIcon(string label)
    {
        using var probe = new Bitmap(1, 1);
        using var g0 = Graphics.FromImage(probe);
        using var font = new Font("Segoe UI", 9f, System.Drawing.FontStyle.Bold, GraphicsUnit.Point);
        var size = g0.MeasureString(label, font);

        var width = Math.Max(16, (int)Math.Ceiling(size.Width));
        var height = Math.Max(16, (int)Math.Ceiling(size.Height));
        var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            var pct = _model?.Usage?.Limits.FirstOrDefault(l => l.Id == "session")?.Percent ?? 0;
            using var brush = new SolidBrush(_model?.Usage is { Limits.Count: > 0 } ? Theme.RampColor(pct) : Color.FromArgb(230, 230, 230));
            g.DrawString(label, font, brush, 0, 0);
        }

        var handle = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        bmp.Dispose();
        return icon;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    protected override void OnExit(ExitEventArgs e)
    {
        _tray.Visible = false;
        _tray.Dispose();
        base.OnExit(e);
    }
}
