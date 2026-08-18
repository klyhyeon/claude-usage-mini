using System.Text.Json;
using ClaudeUsageMini;

var json = """
{
  "five_hour": {"utilization": 16.0, "resets_at": "2026-08-18T05:00:00.324039+00:00"},
  "seven_day": {"utilization": 2.0, "resets_at": "2026-08-23T04:00:00.324062+00:00"},
  "seven_day_fable": {"utilization": 11},
  "limits": [
    {"kind": "session", "percent": 7, "resets_at": "2026-08-18T05:00:00.324039+00:00", "scope": null},
    {"kind": "weekly_all", "percent": 24, "resets_at": "2026-08-23T04:00:00.324062+00:00", "scope": null},
    {"kind": "weekly_scoped", "percent": 43, "resets_at": "2026-08-23T04:00:00.324062+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}}},
    {"kind": "weekly_scoped", "percent": 0, "resets_at": null,
     "scope": {"model": {"id": null, "display_name": "Opus"}}}
  ]
}
""";
using var doc = JsonDocument.Parse(json);
var rows = UsageApi.Parse(doc.RootElement);
void Check(bool cond, string msg) { if (!cond) { Console.Error.WriteLine("FAIL: " + msg); Environment.Exit(1); } }
Check(rows[0].Id == "session" && rows[0].Percent == 7, $"session {rows[0].Percent}");
Check(rows[1].Id == "all" && rows[1].Percent == 24, $"all {rows[1].Percent}");
Check(rows[0].ResetsAt is not null, "fractional-offset timestamp parse");
var models = rows.Skip(2).ToList();
Check(models.Select(m => m.Id).SequenceEqual(new[] {"fable","opus"}), "model order " + string.Join(",", models.Select(m=>m.Id)));
Check(models[0].Percent == 43, $"fable override {models[0].Percent}");
Check(models.All(m => m.Badge == "Weekly"), "badges");
using var empty = JsonDocument.Parse("""{"limits": []}""");
Check(UsageApi.Parse(empty.RootElement).Count == 0, "empty payload");
Console.WriteLine("C# parse check OK");
