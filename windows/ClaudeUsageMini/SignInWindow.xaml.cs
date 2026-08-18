using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace ClaudeUsageMini;

/// <summary>
/// Signs the user in to claude.ai in an embedded web view and lifts the
/// sessionKey cookie out of the shared cookie store, so nobody has to copy it
/// out of DevTools by hand.
/// </summary>
public partial class SignInWindow : Window
{
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _found;
    private int _pollsSinceLoginLeft;
    private int _reloadAttempts;

    public event Action? SignedIn;

    public SignInWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Closed += (_, _) => _poll.Stop();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await Web.EnsureCoreWebView2Async(await CookieJar.EnvironmentAsync());

        // Drop stale Claude cookies so a dead session can't silently auto-login.
        // Third-party SSO cookies stay so the Google popup still works.
        var manager = Web.CoreWebView2.CookieManager;
        foreach (var cookie in await manager.GetCookiesAsync("https://claude.ai"))
            manager.DeleteCookie(cookie);

        // A popup window is how Google SSO completes; reusing the same
        // environment keeps window.opener and the cookie store shared.
        Web.CoreWebView2.NewWindowRequested += OnNewWindowRequested;

        Web.CoreWebView2.Navigate("https://claude.ai/login");

        // The cookie is set by the network stack mid-SPA, with no navigation to
        // hook — polling is the reliable signal.
        _poll.Tick += async (_, _) => await CheckAsync();
        _poll.Start();
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        var popup = new SignInPopup();
        popup.Show();
        popup.AttachAsync(e, deferral);
    }

    private async Task CheckAsync()
    {
        if (_found) { _poll.Stop(); return; }

        var cookies = await CookieJar.ClaudeCookiesAsync();
        if (cookies.Any(c => c.Name == "sessionKey"))
        {
            _found = true;
            _poll.Stop();
            SignedIn?.Invoke();
            Close();
            return;
        }

        // The fresh cookie can stay invisible until the next navigation. If
        // login clearly succeeded but no cookie showed up, force a reload —
        // the same workaround as reloading the page by hand.
        var url = Web.CoreWebView2?.Source ?? "";
        if (!url.Contains("claude.ai") || url.Contains("login"))
        {
            _pollsSinceLoginLeft = 0;
            return;
        }
        if (++_pollsSinceLoginLeft >= 3 && _reloadAttempts < 3)
        {
            _pollsSinceLoginLeft = 0;
            _reloadAttempts++;
            Web.CoreWebView2.Reload();
        }
    }
}
