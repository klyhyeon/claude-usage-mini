using System.Text;

namespace ClaudeUsageMini;

/// <summary>
/// Publishes usage for the Claude Code statusline. Format matches the macOS
/// app and the upstream tracker — KEY=value lines, epoch TIMESTAMP — so the
/// statusline script reads all of them the same way.
/// </summary>
public static class StatuslineCache
{
    private static string Path(string name) => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", name);

    public static void Write(IReadOnlyList<UsageLimit> limits)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var fable = limits.FirstOrDefault(l => l.Id == "fable");
        var session = limits.FirstOrDefault(l => l.Id == "session");
        var weekly = limits.FirstOrDefault(l => l.Id == "all");

        if (fable is not null)
            WriteFile(".statusline-fable-cache", new (string, string?)[]
            {
                ("FABLE_UTILIZATION", $"{Math.Round(fable.Percent)}"),
                ("FABLE_RESETS_AT", Iso(fable.ResetsAt)),
                ("TIMESTAMP", $"{now}"),
            });

        if (session is null && weekly is null) return;
        WriteFile(".statusline-usage-cache", new (string, string?)[]
        {
            ("UTILIZATION", session is null ? null : $"{Math.Round(session.Percent)}"),
            ("RESETS_AT", Iso(session?.ResetsAt)),
            ("TIMESTAMP", $"{now}"),
            ("WEEKLY_UTILIZATION", weekly is null ? null : $"{Math.Round(weekly.Percent)}"),
            ("WEEKLY_RESETS_AT", Iso(weekly?.ResetsAt)),
        });
    }

    private static string? Iso(DateTime? d) => d?.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");

    private static void WriteFile(string name, IEnumerable<(string Key, string? Value)> pairs)
    {
        var body = new StringBuilder();
        foreach (var (key, value) in pairs)
            if (value is not null) body.Append(key).Append('=').Append(value).Append('\n');
        try
        {
            var path = Path(name);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            File.WriteAllText(path, body.ToString());
        }
        catch (IOException) { /* the statusline is a nicety; never break polling over it */ }
        catch (UnauthorizedAccessException) { }
    }
}
