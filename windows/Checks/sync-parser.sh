#!/bin/bash
# Regenerate Checks/Parser.cs from the real parser in UsageApi.cs, so the
# off-Windows parse check stays in step with the app. Run after editing Parse.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
src = open("../ClaudeUsageMini/UsageApi.cs").read()
records = src[src.index("public record UsageLimit"):src.index("public class UsageException")]
start = src.index("    /// <summary>`utilization`")
end = src.index("        return rows;\n    }") + len("        return rows;\n    }")
body = src[start:end]
open("Parser.cs", "w").write(
    "using System.Text.Json;\n\nnamespace ClaudeUsageMini;\n\n"
    + records + "\n\npublic static class UsageApi\n{\n" + body + "\n}\n")
print("Parser.cs regenerated")
PY
