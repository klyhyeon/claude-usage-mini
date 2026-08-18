using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace ClaudeUsageMini;

/// <summary>Host for a window.open() popup — Google SSO does not complete without one.</summary>
public partial class SignInPopup : Window
{
    public SignInPopup() => InitializeComponent();

    public async void AttachAsync(CoreWebView2NewWindowRequestedEventArgs args, CoreWebView2Deferral deferral)
    {
        try
        {
            await Web.EnsureCoreWebView2Async(await CookieJar.EnvironmentAsync());
            args.NewWindow = Web.CoreWebView2;
            args.Handled = true;
            Web.CoreWebView2.WindowCloseRequested += (_, _) => Close();
        }
        finally
        {
            deferral.Complete();
        }
    }
}
