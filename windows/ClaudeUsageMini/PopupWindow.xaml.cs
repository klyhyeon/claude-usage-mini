using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ClaudeUsageMini;

/// <summary>The flyout the tray icon opens — the card list from the mockup.</summary>
public partial class PopupWindow : Window
{
    private readonly UsageModel _model;

    public PopupWindow(UsageModel model)
    {
        InitializeComponent();
        _model = model;
        _model.Changed += Rebuild;
        Rebuild();
    }

    private void OnDeactivated(object? sender, EventArgs e) => Hide();

    public void ToggleAt(int anchorX, int anchorY)
    {
        if (IsVisible) { Hide(); return; }
        Rebuild();
        // Anchor above the tray, right-aligned to the click — the pixels are
        // physical, and PerMonitorV2 keeps WPF's DIP mapping honest.
        var source = PresentationSource.FromVisual(this);
        Show();
        UpdateLayout();
        Left = Math.Max(8, anchorX / (source?.CompositionTarget?.TransformToDevice.M11 ?? 1) - ActualWidth);
        Top = anchorY / (source?.CompositionTarget?.TransformToDevice.M22 ?? 1) - ActualHeight - 8;
        Activate();
    }

    private void Rebuild()
    {
        Root.Children.Clear();

        if (_model.Usage is { Limits.Count: > 0 } usage)
        {
            foreach (var limit in usage.Limits) Root.Children.Add(Card(limit));
        }
        else if (!_model.HasSession)
        {
            Root.Children.Add(Message("Sign in to claude.ai to connect your account.", button: "Sign In", onClick: _model.SignIn));
        }
        else if (_model.Error is { } err)
        {
            Root.Children.Add(Message(err, button: "Sign In Again", onClick: _model.SignIn));
        }
        else
        {
            Root.Children.Add(Message(_model.IsLoading ? "Loading usage…" : "No usage reported yet."));
        }

        Root.Children.Add(Footer());
    }

    private UIElement Card(UsageLimit limit)
    {
        var tint = Theme.Ramp(limit.Percent);
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(new TextBlock { Text = limit.Title, Foreground = Theme.Title, FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        if (limit.Badge is { } badge)
            titleRow.Children.Add(new Border
            {
                Background = Theme.BadgeBg, CornerRadius = new CornerRadius(999),
                Padding = new Thickness(7, 1, 7, 1), Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = badge, Foreground = Theme.Dim, FontSize = 10 },
            });
        header.Children.Add(titleRow);

        var pct = new TextBlock { Text = $"{Math.Round(limit.Percent)}%", Foreground = tint, FontSize = 14, FontWeight = FontWeights.Bold };
        Grid.SetColumn(pct, 1);
        header.Children.Add(pct);
        stack.Children.Add(header);

        if (limit.Subtitle is { } subtitle)
            stack.Children.Add(new TextBlock { Text = subtitle, Foreground = Theme.Dim, FontSize = 11, Margin = new Thickness(0, 4, 0, 0) });

        stack.Children.Add(Bar(limit.Percent, tint));

        if (limit.ResetsAt is { } reset)
            stack.Children.Add(new TextBlock { Text = $"Resets {FormatReset(reset)}", Foreground = Theme.Dim, FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });

        return new Border
        {
            Background = Theme.Card, BorderBrush = Theme.CardBorder, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6), Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8),
            Child = stack,
        };
    }

    private static UIElement Bar(double percent, Brush tint)
    {
        var track = new Border { Background = Theme.Track, CornerRadius = new CornerRadius(2), Height = 4, Margin = new Thickness(0, 8, 0, 0) };
        var fill = new Border { Background = tint, CornerRadius = new CornerRadius(2), Height = 4, HorizontalAlignment = HorizontalAlignment.Left };
        var grid = new Grid();
        grid.Children.Add(track);
        grid.Children.Add(fill);
        grid.Loaded += (_, _) => fill.Width = Math.Max(0, Math.Min(1, percent / 100)) * grid.ActualWidth;
        grid.SizeChanged += (_, _) => fill.Width = Math.Max(0, Math.Min(1, percent / 100)) * grid.ActualWidth;
        return grid;
    }

    private UIElement Message(string text, string? button = null, Action? onClick = null)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = text, Foreground = Theme.Dim, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        if (button is not null)
        {
            var btn = new Button { Content = button, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
            btn.Click += (_, _) => { Hide(); onClick?.Invoke(); };
            stack.Children.Add(btn);
        }
        return new Border { Background = Theme.Card, CornerRadius = new CornerRadius(6), Padding = new Thickness(12), Child = stack };
    }

    private UIElement Footer()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (_model.Usage is { } usage)
            grid.Children.Add(new TextBlock { Text = $"Updated {usage.FetchedAt:h:mm tt}", Foreground = Theme.Faint, FontSize = 10, VerticalAlignment = VerticalAlignment.Center });

        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var refresh = new Button { Content = "Refresh", Margin = new Thickness(0, 0, 12, 0), Foreground = Theme.Dim, Background = Brushes.Transparent, BorderThickness = new Thickness(0), FontSize = 11, Cursor = System.Windows.Input.Cursors.Hand };
        refresh.Click += async (_, _) => await _model.RefreshAsync();
        var quit = new Button { Content = "Quit", Foreground = Theme.Dim, Background = Brushes.Transparent, BorderThickness = new Thickness(0), FontSize = 11, Cursor = System.Windows.Input.Cursors.Hand };
        quit.Click += (_, _) => Application.Current.Shutdown();
        actions.Children.Add(refresh);
        actions.Children.Add(quit);
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);
        return grid;
    }

    private static string FormatReset(DateTime date)
    {
        var time = date.ToString("h:mm tt", CultureInfo.InvariantCulture);
        if (date.Date == DateTime.Today) return $"Today {time}";
        if (date.Date == DateTime.Today.AddDays(1)) return $"Tomorrow {time}";
        return $"{date:MMM d}, {time}";
    }
}
