using System.Windows.Threading;

namespace ClaudeUsageMini;

/// <summary>Owns the polling loop and the observable state the popup + tray render.</summary>
public class UsageModel
{
    private readonly UsageApi _api = new();
    private readonly DispatcherTimer _timer;
    private bool _isLoading;

    public Usage? Usage { get; private set; }
    public string? Error { get; private set; }
    public bool IsLoading => _isLoading;
    public bool HasSession { get; private set; }

    /// <summary>Fires on the UI thread whenever the rendered state changes.</summary>
    public event Action? Changed;

    public UsageModel()
    {
        // claude.ai rate-limits aggressive polling; 60s matches the macOS app.
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        _ = RefreshAsync();
    }

    /// <summary>Session %, Fable weekly in parentheses, session reset — "25%(1%) · 2:00pm".</summary>
    public string TrayLabel()
    {
        if (Usage is not { Limits.Count: > 0 } usage) return "—";
        var session = usage.Limits.FirstOrDefault(l => l.Id == "session");
        var pct = session?.Percent ?? usage.Limits.Max(l => l.Percent);
        var label = $"{Math.Round(pct)}%";
        var fable = usage.Limits.FirstOrDefault(l => l.Id == "fable");
        if (fable is not null) label += $"({Math.Round(fable.Percent)}%)";
        if (session?.ResetsAt is { } reset) label += " · " + ShortTime(reset);
        return label;
    }

    private static string ShortTime(DateTime date)
    {
        var minute = date.Minute.ToString("D2");
        var suffix = date.Hour < 12 ? "am" : "pm";
        var hour = date.Hour % 12;
        if (hour == 0) hour = 12;
        return $"{hour}:{minute}{suffix}";
    }

    public async Task RefreshAsync()
    {
        if (_isLoading) return;
        _isLoading = true;
        Changed?.Invoke();
        try
        {
            HasSession = await CookieJar.HeaderAsync() is not null;
            var usage = await _api.FetchAsync();
            Usage = usage;
            Error = null;
            StatuslineCache.Write(usage.Limits);
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
        finally
        {
            _isLoading = false;
            Changed?.Invoke();
        }
    }

    public void SignIn()
    {
        var window = new SignInWindow();
        window.SignedIn += () => _ = RefreshAsync();
        window.Show();
        window.Activate();
    }
}
