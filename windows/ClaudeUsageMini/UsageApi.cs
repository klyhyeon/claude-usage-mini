using System.Net.Http;
using System.Text.Json;

namespace ClaudeUsageMini;

/// <summary>One usage limit row as the popup renders it.</summary>
public record UsageLimit(string Id, string Title, string? Badge, string? Subtitle, double Percent, DateTime? ResetsAt);

public record Usage(IReadOnlyList<UsageLimit> Limits, DateTime FetchedAt);

public class UsageException : Exception
{
    public UsageException(string message) : base(message) { }
}

/// <summary>
/// Reads usage from claude.ai's web API. Authentication is the browser session
/// cookie, so every request carries the WebView2 cookie jar and a browser
/// User-Agent — a bare sessionKey gets a Cloudflare 403 challenge page.
/// </summary>
public class UsageApi
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private string? _cachedOrgId;

    public async Task<Usage> FetchAsync()
    {
        var cookies = await CookieJar.HeaderAsync();
        if (string.IsNullOrEmpty(cookies)) throw new UsageException("Not signed in. Click Sign In to connect your Claude account.");

        foreach (var orgId in await OrganizationIdsAsync(cookies))
        {
            using var doc = await GetAsync($"/organizations/{orgId}/usage", cookies);
            var limits = Parse(doc.RootElement);
            if (limits.Count > 0)
            {
                _cachedOrgId = orgId;
                return new Usage(limits, DateTime.Now);
            }
        }
        _cachedOrgId = null;
        return new Usage(Array.Empty<UsageLimit>(), DateTime.Now);
    }

    private async Task<List<string>> OrganizationIdsAsync(string cookies)
    {
        if (_cachedOrgId is not null) return new List<string> { _cachedOrgId };

        using var doc = await GetAsync("/organizations", cookies);
        var subscription = new List<string>();
        var rest = new List<string>();
        foreach (var org in doc.RootElement.EnumerateArray())
        {
            if (!org.TryGetProperty("uuid", out var uuid) || uuid.GetString() is not { } id) continue;
            // The subscription lives on the org whose capabilities include
            // "raven"; a personal org sits alongside it and reports a flat 0%.
            var isSubscription = org.TryGetProperty("capabilities", out var caps)
                && caps.ValueKind == JsonValueKind.Array
                && caps.EnumerateArray().Any(c => c.GetString() == "raven");
            (isSubscription ? subscription : rest).Add(id);
        }
        var ids = subscription.Concat(rest).ToList();
        if (ids.Count == 0) throw new UsageException("No organization on this account.");
        return ids;
    }

    private static async Task<JsonDocument> GetAsync(string path, string cookies)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://claude.ai/api" + path);
        request.Headers.Add("Cookie", cookies);
        request.Headers.Add("Accept", "application/json");
        request.Headers.Add("User-Agent", CookieJar.UserAgent);
        request.Headers.Add("Referer", "https://claude.ai");
        request.Headers.Add("Origin", "https://claude.ai");

        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        if (Environment.GetEnvironmentVariable("CUM_DEBUG") == "1")
            Console.Error.WriteLine($"[{path}] HTTP {(int)response.StatusCode}\n{body}");

        if ((int)response.StatusCode is 401 or 403)
            throw new UsageException("Session expired. Sign in again to reconnect.");
        if (!response.IsSuccessStatusCode)
            throw new UsageException($"claude.ai returned HTTP {(int)response.StatusCode}.");

        return JsonDocument.Parse(body);
    }

    // MARK: parsing

    /// <summary>`utilization` / `percent` arrive as either a number or a numeric string.</summary>
    private static double? Percent(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.Number => v.GetDouble(),
            JsonValueKind.String => double.TryParse(v.GetString(), out var d) ? d : null,
            _ => null,
        };
    }

    private static DateTime? Reset(JsonElement parent, string name)
        => parent.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
           && DateTime.TryParse(v.GetString(), out var d) ? d.ToLocalTime() : null;

    private static (double Pct, DateTime? Reset)? Block(JsonElement json, string key)
    {
        if (!json.TryGetProperty(key, out var dict) || dict.ValueKind != JsonValueKind.Object) return null;
        if (Percent(dict, "utilization") is not { } pct) return null;
        return (pct, Reset(dict, "resets_at"));
    }

    public static List<UsageLimit> Parse(JsonElement json)
    {
        var session = Block(json, "five_hour");
        var all = Block(json, "seven_day");

        // Legacy per-model fields; newer responses null these out and report the
        // same numbers in `limits[]`, which overrides whatever lands here.
        var models = new Dictionary<string, (string Title, double Pct, DateTime? Reset)>();
        foreach (var (key, title) in new[] { ("seven_day_fable", "Fable"), ("seven_day_opus", "Opus"),
                                             ("seven_day_sonnet", "Sonnet"), ("seven_day_omelette", "Design") })
            if (Block(json, key) is { } b) models[title.ToLowerInvariant()] = (title, b.Pct, b.Reset);

        if (json.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
        {
            foreach (var limit in limits.EnumerateArray())
            {
                if (Percent(limit, "percent") is not { } pct) continue;
                var reset = Reset(limit, "resets_at");
                switch (limit.TryGetProperty("kind", out var k) ? k.GetString() : null)
                {
                    case "session": session = (pct, reset); break;
                    case "weekly_all": all = (pct, reset); break;
                    case "weekly_scoped":
                        if (!limit.TryGetProperty("scope", out var scope) || scope.ValueKind != JsonValueKind.Object) continue;
                        if (!scope.TryGetProperty("model", out var model) || model.ValueKind != JsonValueKind.Object) continue;
                        // Match the stable model id when there is one;
                        // display_name is a rename-prone human label.
                        var modelId = (model.TryGetProperty("id", out var mid) ? mid.GetString() : null)?.ToLowerInvariant() ?? "";
                        var name = (model.TryGetProperty("display_name", out var dn) ? dn.GetString() : null) ?? "";
                        var key = name.ToLowerInvariant();
                        var title = name;
                        foreach (var (aliases, canonical) in new[] {
                            (new[] { "fable", "mythos" }, "Fable"), (new[] { "opus" }, "Opus"),
                            (new[] { "sonnet" }, "Sonnet"), (new[] { "design", "omelette" }, "Design") })
                        {
                            if (!aliases.Any(a => key == a || modelId.Contains(a))) continue;
                            key = aliases[0];
                            title = canonical;
                        }
                        if (key.Length == 0) continue;
                        models[key] = (title, pct, reset);
                        break;
                }
            }
        }

        var rows = new List<UsageLimit>();
        if (session is { } s) rows.Add(new UsageLimit("session", "Session Usage", null, "5-hour rolling window", s.Pct, s.Reset));
        if (all is { } a) rows.Add(new UsageLimit("all", "All models", "Weekly", null, a.Pct, a.Reset));
        // Every model the API reports is shown, 0% included — a model missing
        // from the popup reads as a bug, not as "nothing used yet".
        rows.AddRange(models
            .Select(m => new UsageLimit(m.Key, m.Value.Title, "Weekly", null, m.Value.Pct, m.Value.Reset))
            .OrderByDescending(r => r.Percent).ThenBy(r => r.Title));
        return rows;
    }
}
