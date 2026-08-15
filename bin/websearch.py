#!/usr/bin/env python3
"""ViddyDictate web-search helper (Option+L / Option+G search backend).

The Swift app shells to this via the production venv (~/.local/share/viddydictate/venv):
    printf '{"query":"...","maxResults":6}' | python websearch.py
and reads a JSON array of results from stdout:
    [{"title": "...", "href": "...", "body": "..."}, ...]

Why a Python helper (not native Swift or the zero-dep Node web MCP server): the bench proved
DuckDuckGo's raw HTML endpoint walls off scrapers with a 202 anomaly response (0 parseable
results), so the maintained `ddgs` library — which rotates html/lite/api backends and backs off —
is the robust source. This is the same backend the signed-off process-shape bench used, carried
verbatim (throttle + retry/backoff) into production.

Stdout is ALWAYS a JSON array (possibly empty); a hard failure prints `[]` and exits 0 so the
caller never has to parse a stderr error — an empty array degrades gracefully to "no results".
Diagnostics go to stderr only.
"""
import contextlib, io, json, sys, time

MAX_RESULTS_DEFAULT = 6
RETRIES = 3
BACKOFF = 4.0  # seconds, multiplied by attempt number on a rate-limit / transient error


def web_search(query, max_results=MAX_RESULTS_DEFAULT, retries=RETRIES):
    """DuckDuckGo via ddgs, retried with backoff on the 202 rate-limit / transient errors. Returns
    a list of {title, href, body} dicts (empty on persistent failure)."""
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            from ddgs import DDGS
    except Exception as e:  # ddgs not installed in the venv — caller gets [] and degrades.
        print(f"websearch: import_failed exception={type(e).__name__}", file=sys.stderr)
        return []
    last_classification = "empty_results"
    for attempt in range(retries):
        try:
            # Third-party diagnostics are not part of the helper protocol and may include request
            # material. Capture and discard them; emit only classifications/counts below.
            with contextlib.redirect_stderr(io.StringIO()):
                rows = DDGS().text(query, max_results=max_results) or []
            out = [{"title": r.get("title", ""), "href": r.get("href", ""),
                    "body": r.get("body", "")} for r in rows]
            if out:
                return out
            # Empty but no exception: likely a transient throttle. Back off and retry.
            last_classification = "empty_results"
        except Exception as e:  # ddgs raises RatelimitException etc.
            last_classification = f"exception_{type(e).__name__}"
        if attempt < retries - 1:
            time.sleep(BACKOFF * (attempt + 1))
    print(f"websearch: search_failed classification={last_classification} attempts={retries}",
          file=sys.stderr)
    return []


def read_request():
    try:
        request = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, UnicodeError):
        print("websearch: protocol_error classification=invalid_json", file=sys.stderr)
        return None
    if not isinstance(request, dict):
        print("websearch: protocol_error classification=request_not_object", file=sys.stderr)
        return None
    query = request.get("query")
    if not isinstance(query, str):
        print("websearch: protocol_error classification=query_not_string", file=sys.stderr)
        return None
    max_results = MAX_RESULTS_DEFAULT
    requested_max = request.get("maxResults")
    if isinstance(requested_max, int) and not isinstance(requested_max, bool):
        max_results = max(1, min(10, requested_max))
    return query.strip(), max_results


def main():
    if len(sys.argv) != 1:
        print(f"websearch: protocol_error classification=unexpected_argv argv_count={len(sys.argv) - 1}",
              file=sys.stderr)
        print("[]")
        return 0
    request = read_request()
    if request is None:
        print("[]")
        return 0
    query, max_results = request
    if not query:
        print("[]")
        return 0
    results = web_search(query, max_results)
    print(json.dumps(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
