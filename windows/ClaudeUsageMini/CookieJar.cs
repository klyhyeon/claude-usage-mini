using Microsoft.Web.WebView2.Core;

namespace ClaudeUsageMini;

/// <summary>
/// Source of the cookies the API calls travel with.
///
/// A bare sessionKey is not enough: claude.ai sits behind Cloudflare, which
/// answers an unrecognised client with a 403 challenge page. The sign-in web
/// view holds the cf_clearance / __cf_bm cookies that clear it, so every
/// request reuses the WebView2 cookie store rather than a saved key.
/// </summary>
public static class CookieJar
{
    /// <summary>Browser UA — Cloudflare rejects the default HttpClient agent string.</summary>
    public const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/128.0.0.0 Safari/537.36";

    /// <summary>The user-data folder every WebView2 in this app shares, so the
    /// sign-in window's cookies are the ones the poller reads.</summary>
    public static string UserDataFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ClaudeUsageMini", "WebView2");

    private static CoreWebView2Environment? _environment;

    public static async Task<CoreWebView2Environment> EnvironmentAsync()
    {
        Directory.CreateDirectory(UserDataFolder);
        return _environment ??= await CoreWebView2Environment.CreateAsync(null, UserDataFolder);
    }

    /// <summary>Exact-or-suffix match. Contains("claude.ai") would also accept a
    /// registrable lookalike such as notclaude.ai, letting a hostile page plant
    /// a cookie this app would then treat as the real session.</summary>
    public static bool IsClaudeDomain(string domain)
    {
        var d = domain.StartsWith('.') ? domain[1..] : domain;
        return d.Equals("claude.ai", StringComparison.OrdinalIgnoreCase)
            || d.EndsWith(".claude.ai", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Cookie header for claude.ai, or null when the user has not signed in.</summary>
    public static async Task<string?> HeaderAsync()
    {
        var cookies = await ClaudeCookiesAsync();
        if (!cookies.Any(c => c.Name == "sessionKey")) return null;
        return string.Join("; ", cookies.Select(c => $"{c.Name}={c.Value}"));
    }

    public static async Task<List<CoreWebView2Cookie>> ClaudeCookiesAsync()
    {
        // CookieManager needs a CoreWebView2; an off-screen one is the
        // documented way to reach the shared store without a visible window.
        var manager = await HeadlessManagerAsync();
        var cookies = await manager.GetCookiesAsync("https://claude.ai");
        return cookies.Where(c => IsClaudeDomain(c.Domain)).ToList();
    }

    private static CoreWebView2? _headless;
    private static readonly SemaphoreSlim HeadlessLock = new(1, 1);

    private static async Task<CoreWebView2CookieManager> HeadlessManagerAsync()
    {
        await HeadlessLock.WaitAsync();
        try
        {
            if (_headless is null)
            {
                var controller = await (await EnvironmentAsync())
                    .CreateCoreWebView2ControllerAsync(HiddenHost.Handle);
                controller.IsVisible = false;
                _headless = controller.CoreWebView2;
            }
            return _headless.CookieManager;
        }
        finally
        {
            HeadlessLock.Release();
        }
    }
}

/// <summary>A never-shown message-only window to host the headless WebView2.</summary>
internal static class HiddenHost
{
    private static readonly System.Windows.Forms.Form Form = CreateForm();

    public static IntPtr Handle => Form.Handle;

    private static System.Windows.Forms.Form CreateForm()
    {
        var form = new System.Windows.Forms.Form
        {
            ShowInTaskbar = false,
            WindowState = System.Windows.Forms.FormWindowState.Minimized,
            FormBorderStyle = System.Windows.Forms.FormBorderStyle.None,
            Opacity = 0,
            Size = new System.Drawing.Size(1, 1),
        };
        // Realise the handle without ever presenting the window.
        _ = form.Handle;
        return form;
    }
}
