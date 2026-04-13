You are a senior software engineer performing a code audit.

Analyse this repository and identify bugs: logical errors, unhandled exceptions,
missing edge case handling, null dereferences, off-by-one errors, race conditions,
resource leaks, incorrect error propagation, etc.

Open Pull Requests (already in progress - do NOT suggest these):
${open_pr_summary}

Respond ONLY with a valid JSON object, no markdown fences, no explanation:
{
  "bugs": [
    {
      "id": "BUG-001",
      "title": "Concise one-line title (max 72 chars)",
      "severity": "critical|high|medium|low",
      "type": "unhandled_exception|logical_error|edge_case|null_deref|resource_leak|race_condition|security|data_integrity|error_swallowing|infinite_loop|incorrect_async|api_misuse|other",
      "file": "relative/path/to/file.ext",
      "line_hint": 42,
      "description": "Clear 2-3 sentence description of the bug and its impact",
      "already_in_progress": false
    }
  ]
}

Rules:
- Only include REAL bugs visible in the source code
- Mark already_in_progress=true if the bug matches an open PR
- Limit to the top 10 most important bugs, sorted by severity
- If no meaningful bugs exist, return {"bugs": []}
- Bug type guidance:
  unhandled_exception: missing try/catch or error propagation gaps
  logical_error: wrong operators, incorrect conditionals, flawed algorithms
  edge_case: empty input, zero, negatives, boundary values not handled
  null_deref: nil/null/undefined access without guards
  resource_leak: unclosed files, DB connections, sockets, handles
  race_condition: shared mutable state, async timing issues
  security: SQL injection, XSS, hardcoded secrets, path traversal, insecure deserialization
  data_integrity: missing input validation, type coercion bugs, silent truncation on writes
  error_swallowing: caught exceptions silently discarded without logging or re-raising
  infinite_loop: missing termination conditions in loops, retries, or recursion
  incorrect_async: missing await, unhandled promise rejections, callbacks after stream close
  api_misuse: wrong arguments to library functions, ignored error return values
