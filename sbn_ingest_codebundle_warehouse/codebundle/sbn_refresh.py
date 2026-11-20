"""
sbn_refresh.py  —  the SBN API client and database load logic
=============================================================

WHAT THIS FILE DOES
-------------------
Everything that actually talks to the SBN API or writes to Snowflake lives
here. It is called by two different callers:

  1. sbn_daily.py (sbn_ingest_codebundle_warehouse Code Bundle on a warehouse):
       result = sbn_refresh.run(session, days_back=30, mode='load', ...)

  2. The SBN_REFRESH stored procedure (sbn_ingest_sproc_warehouse):
       def main(session, days_back=30, mode='load'):
           ...calls run() after reading the secret...

Both callers pass the same arguments; this file doesn't know or care which
one is running it.

HOW TO READ THIS FILE
---------------------
It has three parts, in order:
  1. The Sbn class  —  the API client (login, GET, paging, count checks)
  2. Helper functions  —  date math and staging data to Snowflake temp tables
  3. run() and _check()  —  the top-level logic (what pulls to do, in what order,
                             how to apply them to the three VARIANT tables)

THE THREE VARIANT TABLES
------------------------
Nothing is flattened here. Every API record is stored exactly as the API
returned it, as a VARIANT (JSON) column:

  SBN_JOBS_RAW   — one row per inspection job, any status
  SBN_USERS_RAW      — one row per SBN user (replaced in full every run)
  SBN_CHECKLISTS_RAW — one row per checklist (replaced in full every run)

Flattening (turning PAYLOAD:field_name into actual columns) is done
downstream from these tables — in a view, dynamic table, or dbt model —
so a schema change in the API only needs a fix in the flatten logic, not here.
"""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# The base URL for the real SBN API. sbn_daily.py uses this by default.
# The mock and test harnesses override it via the base_url argument to run().
DEFAULT_BASE_URL = "https://wks.simplebutneeded.net/api/v1"

PAGE_SIZE = 500      # how many records to ask for per API page
TIMEOUT = (5, 35)    # (connect timeout, read timeout) in seconds
                     # read timeout is set above the API's 30s server timeout
MODIFIED_MAX_DAYS = 30   # the modified-jobs pull never goes further back than
                          # this, even on a long history load (saves API calls)


# =============================================================================
# CUSTOM ERROR CLASS
# Used for two things:
#   - API failures (bad HTTP status, can't connect, etc.)
#   - Count-check failures (we got fewer records than the API said we should)
# Raising SbnError causes the CALL or EXECUTE CODE BUNDLE to fail, which makes
# the scheduled task retry and then alert, rather than silently inserting
# incomplete data.
# =============================================================================
class SbnError(RuntimeError):
    pass


# =============================================================================
# THE SBN API CLIENT (the Sbn class)
#
# This is a Python "class" — think of it as a bundle of functions that all
# share the same HTTP session (cookies, headers, retry settings). You create
# one with:
#   api = Sbn(base_url, username, password)
# and then call its methods like api.paginate(...) or api.count(...).
# =============================================================================
class Sbn:
    def __init__(self, base_url: str, username: str, password: str):
        """
        Called once to set up the API client. Checks the URL is HTTPS, then
        immediately logs in. By the time __init__ finishes, the client is
        ready to make authenticated API calls.
        """
        if not base_url.startswith("https://"):
            raise ValueError(f"Base URL must use HTTPS, got: {base_url!r}")
        self.base = base_url.rstrip("/")
        self._username, self._password = username, password

        # requests.Session() is a persistent HTTP connection with shared cookies
        # and headers — more efficient than opening a new connection per request.
        self.http = requests.Session()

        # Automatically retry on rate-limit (429) and server errors (5xx) with
        # exponential back-off: waits 0.5s, 1s, 2s, 4s, 8s before giving up.
        # This is the same retry logic the original sbn_common.py used.
        self.http.mount("https://", HTTPAdapter(max_retries=Retry(
            total=5, backoff_factor=0.5, status_forcelist=[429, 500, 502, 503, 504],
            respect_retry_after_header=True, raise_on_status=False)))

        self.login()   # authenticate immediately; sets the session cookie

    # -------------------------------------------------------------------------
    def login(self) -> None:
        """
        POST to /core/user/login/ with username and password.
        The API returns a session token (cookie or response body).
        We store it in the Authorization header so every future GET is
        authenticated automatically.
        """
        r = self.http.post(f"{self.base}/core/user/login/",
                           data={"username": self._username, "password": self._password}, timeout=TIMEOUT)
        if not r.ok:
            raise SbnError(f"login: HTTP {r.status_code}")

        # Try the cookie first; fall back to the response body if the cookie
        # isn't set (matches the same fallback logic in the original sbn_common.py)
        sid = self.http.cookies.get("sessionid")
        if not sid:
            try:
                body = r.json()
            except ValueError:
                body = {}
            if isinstance(body, dict):
                sess = body.get("session")
                sid = (sess.get("id") or sess.get("key")) if isinstance(sess, dict) else sess
                sid = sid or body.get("sessionid") or body.get("key")
        if not sid:
            raise SbnError("login succeeded but no session token was returned")

        # Set the Authorization header on every future request in this session
        self.http.headers.update({"Authorization": f"session {sid}", "Accept": "application/json"})

    # -------------------------------------------------------------------------
    def get(self, path: str, params: dict | None = None) -> dict:
        """
        GET a single page from the API. If the response is 401 (session
        expired), log in again once and retry. Any other error raises SbnError.
        Returns the parsed JSON as a Python dict.
        """
        for attempt in (1, 2):
            r = self.http.get(f"{self.base}{path}", params=params, timeout=TIMEOUT)
            if r.status_code == 401 and attempt == 1:
                self.login()   # session expired mid-run; re-authenticate and try once more
                continue
            if not r.ok:
                raise SbnError(f"GET {path}: HTTP {r.status_code}")
            return r.json() if r.text else {}
        raise SbnError(f"GET {path}: still 401 after re-login")

    # -------------------------------------------------------------------------
    def count(self, path: str, filters: dict | None = None) -> int:
        """
        Ask the API how many records match a filter, without pulling them.
        Uses the /count/ sub-endpoint, e.g. /inspection/job/count/?job_status=completed.
        This is used as a cross-check: after pulling all pages, we compare the
        count we got to the count the API said we should have gotten.
        """
        return int(self.get(f"{path}count/", filters).get("count", 0))

    # -------------------------------------------------------------------------
    def paginate(self, path: str, filters: dict | None = None) -> list[dict]:
        """
        Pull ALL records for a resource, page by page.

        HOW PAGING WORKS:
        Instead of "give me page 1, page 2, page 3..." (which can miss records
        if data changes mid-pull), we use keyset paging: "give me the next
        PAGE_SIZE records with id > last_id_we_saw". This is safer.
        We stop when the API returns an empty page.

        DEDUPLICATION: If two pages overlap (same id appears twice), the dict
        keyed by id keeps only the latest copy.

        INFINITE LOOP GUARD: If the last id doesn't advance, the loop would
        run forever. We detect that and raise an error.
        """
        by_id: dict = {}
        last_id = 0
        while True:
            rows = self.get(path, {**(filters or {}), "ordering": "id", "id__gt": last_id,
                                   "limit": PAGE_SIZE}).get("results", [])
            if not rows:
                break   # empty page = we've seen everything
            for row in rows:
                by_id[row["id"]] = row   # dedupe: later page wins on same id
            if rows[-1]["id"] <= last_id:
                raise SbnError(f"{path}: id did not advance past {last_id} (server ignored id__gt?)")
            last_id = rows[-1]["id"]
        return list(by_id.values())

    # -------------------------------------------------------------------------
    # The three pulls, each with their count check.
    # Each one raises SbnError if we got fewer records than the API said we
    # should have — better to fail loudly than to insert partial data silently.
    # -------------------------------------------------------------------------

    def lookup(self, path: str) -> list[dict]:
        """
        Pull a small reference table (users, checklists) in full.
        Checks the total count before and raises if the pull came up short.
        """
        expected = self.count(path)
        rows = self.paginate(path)
        if len(rows) < expected:
            raise SbnError(f"{path} lookup short: got {len(rows)}, API count {expected}")
        return rows

    def completed(self, gte: str, lt: str) -> list[dict]:
        """
        Pull completed jobs whose completion_date falls in [gte, lt).
        Counts before AND after the pull — takes the larger as the floor —
        because a job can be completed while we're mid-pull.
        This is the same rule the original sbn_common.fetch_completed_jobs used.
        """
        f = {"job_status": "completed", "completion_date__gte": gte, "completion_date__lt": lt}
        before = self.count("/inspection/job/", f)
        rows = self.paginate("/inspection/job/", f)
        after = self.count("/inspection/job/", f)
        if len(rows) < max(before, after):
            raise SbnError(f"completed-window pull {gte}..{lt} short: got {len(rows)}, "
                           f"API count before={before} after={after}")
        return rows

    def modified(self, gte: str) -> list[dict]:
        """
        Pull ALL jobs (any status) modified since gte. This catches edits and
        reopened jobs that the completed-jobs pull would otherwise miss.

        Uses only the BEFORE count (not after), because a job modified during
        the pull would inflate the AFTER count and cause a false failure —
        the next daily run will pick it up anyway.
        """
        f = {"modified__gte": gte}
        before = self.count("/inspection/job/", f)
        rows = self.paginate("/inspection/job/", f)
        if len(rows) < before:
            raise SbnError(f"modified-window pull short: got {len(rows)}, API count before the pull {before}")
        return rows


# =============================================================================
# HELPER FUNCTIONS (used inside run() below)
# =============================================================================

def _iso(d: date) -> str:
    """
    Turn a Python date into an ISO 8601 string at midnight UTC.
    The SBN API's date filters expect this format.
    Example: date(2026, 11, 1) → '2026-11-01T00:00:00+00:00'
    """
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc).isoformat()


def _months(start: date, end: date) -> list[tuple[date, date]]:
    """
    Split the date range start..end into month-sized windows.
    Returns a list of (window_start, window_end) pairs.
    Example: Jan 15 to Mar 10 → [(Jan 15, Feb 1), (Feb 1, Mar 1), (Mar 1, Apr 1)]

    WHY MONTH WINDOWS?
    The completed-jobs pull does a count-check on each window. If the window
    is 18 months long, any new completion during the pull inflates the count and
    triggers a false failure. Month-sized windows keep the count check tight.
    This is the same approach the original sbn_common.month_starts used.
    """
    out, cur = [], date(start.year, start.month, 1)
    while cur <= end:
        nxt = date(cur.year + 1, 1, 1) if cur.month == 12 else date(cur.year, cur.month + 1, 1)
        out.append((max(cur, start), nxt))
        cur = nxt
    return out


def _upload(session, name: str, rows: list[dict]) -> None:
    """
    Load a list of API records into a temporary Snowflake table.
    The table has two columns: ID (the record's integer id) and PAYLOAD
    (the full JSON as a string). It lives only for this session — Snowflake
    drops it automatically when the run ends.

    This is an intermediate step before the MERGE below. We stage here first
    so the MERGE can run as a single SQL statement (fast, atomic, inside a
    transaction), rather than row-by-row inserts from Python (slow).
    """
    from snowflake.snowpark.types import LongType, StringType, StructField, StructType
    schema = StructType([StructField("ID", LongType()), StructField("PAYLOAD", StringType())])
    data = [[r["id"], json.dumps(r)] for r in rows]   # serialize each record to a JSON string
    session.create_dataframe(data, schema=schema).write.save_as_table(
        name, mode="overwrite", table_type="temporary")


# =============================================================================
# THE TOP-LEVEL LOGIC
# =============================================================================

def run(session, days_back: int, mode: str, base_url: str, username: str, password: str) -> str:
    """
    The main entry point. Called by sbn_daily.py and by the stored procedure's
    main() function. Returns a one-line result string.

    WHAT IT DOES (in 'load' mode):
      1. Pull users and checklists in full (always, every run — they're small)
      2. Pull completed jobs month by month for the requested window
      3. Pull any job modified in the last 30 days (catches edits + reopened jobs)
      4. Union jobs by id (completed-window copy wins over modified-window copy)
      5. Stage everything into temp tables
      6. Apply all three tables in one transaction:
           SBN_USERS_RAW, SBN_CHECKLISTS_RAW  → INSERT OVERWRITE (replace in full)
           SBN_JOBS_RAW              → MERGE on id
                                       new id  → INSERT
                                       same id, newer + different → UPDATE
                                       same id, same content     → skip
    """
    api = Sbn(base_url, username, password)
    today = date.today()

    # 'check' mode: read-only API health check; writes nothing. See _check() below.
    if mode == "check":
        return _check(api, today)
    if mode != "load":
        raise ValueError(f"mode must be 'load' or 'check', got {mode!r}")

    # ----- STEP 1: Reference data (users, checklists) -----
    # These are small tables that are always replaced in full.
    users = api.lookup("/core/user/")
    checklists = api.lookup("/inspection/checklist/")

    # ----- STEP 2: Jobs -----
    # Pull completed jobs in the window, one month at a time.
    start = today - timedelta(days=days_back)
    completed = []
    for lo, hi in _months(start, today):
        completed += api.completed(_iso(lo), _iso(hi))

    # Pull any job modified in the last 30 days (even if it's not completed).
    # This catches: an inspector editing a completed job, or a job being reopened.
    # On a long history load we cap this at 30 days — pulling 18 months of
    # modified jobs on a fresh table would be wasted work.
    modified = api.modified(_iso(today - timedelta(days=min(days_back, MODIFIED_MAX_DAYS))))

    # Union the two pulls by id. If the same job appears in both, the
    # completed-window copy wins (it has the most specific date filter applied).
    by_id = {j["id"]: j for j in modified}
    by_id.update({j["id"]: j for j in completed})
    jobs = list(by_id.values())

    # ----- STEP 3: Stage to temp tables -----
    _upload(session, "SBN_FRESH_USERS", users)
    _upload(session, "SBN_FRESH_CHECKLISTS", checklists)
    _upload(session, "SBN_FRESH_JOBS", jobs)

    # SBN_TS() is a SQL function defined in 02_tables.sql. It parses the
    # API's timestamp strings into a TIMESTAMP_NTZ so we can compare them.
    recency = lambda p: (f"COALESCE(SBN_TS({p}:modified), SBN_TS({p}:created), "
                         f"'1900-01-01'::TIMESTAMP_NTZ)")

    # ----- STEP 4: Apply everything in one transaction -----
    # If any part fails, ROLLBACK undoes everything — no partial writes.
    session.sql("BEGIN").collect()
    try:
        # Users and checklists: replace entirely (INSERT OVERWRITE drops all old rows first)
        session.sql("INSERT OVERWRITE INTO SBN_USERS_RAW SELECT ID, PARSE_JSON(PAYLOAD), CURRENT_TIMESTAMP() "
                    "FROM SBN_FRESH_USERS").collect()
        session.sql("INSERT OVERWRITE INTO SBN_CHECKLISTS_RAW SELECT ID, PARSE_JSON(PAYLOAD), CURRENT_TIMESTAMP() "
                    "FROM SBN_FRESH_CHECKLISTS").collect()

        # Jobs: MERGE on id (never delete, never replace — append / update only)
        # A new id    → INSERT (first time we've ever seen this job)
        # Same id, fresher and different content → UPDATE (job was edited or reopened)
        # Same id, same content → no change (idempotent: re-running is safe)
        res = session.sql(f"""
            MERGE INTO SBN_JOBS_RAW t
            USING (SELECT ID, PARSE_JSON(PAYLOAD) AS P FROM SBN_FRESH_JOBS) s
              ON t.ID = s.ID
            WHEN MATCHED AND {recency('s.P')} >= {recency('t.PAYLOAD')}
                         AND HASH(s.P) <> HASH(t.PAYLOAD) THEN UPDATE SET
              MODIFIED = SBN_TS(s.P:modified), PAYLOAD = s.P, LOADED_AT = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (ID, MODIFIED, PAYLOAD, LOADED_AT)
              VALUES (s.ID, SBN_TS(s.P:modified), s.P, CURRENT_TIMESTAMP())
        """).collect()[0].as_dict()
        session.sql("COMMIT").collect()
    except Exception:
        session.sql("ROLLBACK").collect()
        raise

    # Build the result string (this is what shows up in Run history)
    count = lambda word: next((int(v) for k, v in res.items() if word in k.lower()), 0)
    not_completed = sum(1 for j in jobs if j.get("job_status") != "completed")
    return (f"OK: days_back={days_back}; pulled {len(jobs)} jobs ({not_completed} not completed), "
            f"{len(users)} users, {len(checklists)} checklists; "
            f"SBN_JOBS_RAW: {count('inserted')} inserted, {count('updated')} updated")


def _check(api: Sbn, today: date) -> str:
    """
    Read-only health check. Verifies three behaviors the daily load depends on.
    Writes nothing to the database. Called with --mode check (step 4 of setup).

    Check 1: Does the API return up to PAGE_SIZE records per page?
             If it caps lower, our paging logic handles it (just more requests).

    Check 2: Does the /count/ endpoint accept the modified__gte filter?
             If not, every daily load would fail — this is a REQUIRED check
             before scheduling. The function raises (fails the run) if this fails.

    Check 3: Do reopened jobs get a new modified date?
             If yes, the modified-jobs pull will catch them.
             If not, we might miss some reopened jobs — worth confirming with SBN.
    """
    since = _iso(today - timedelta(days=MODIFIED_MAX_DAYS))
    lines = []

    # Check 1: page size
    n_users = api.count("/core/user/")
    got = len(api.get("/core/user/", {"ordering": "id", "id__gt": 0, "limit": PAGE_SIZE}).get("results", []))
    lines.append(f"1. Page size: asked {PAGE_SIZE}, got {got} (users {n_users}): "
                 + ("OK" if got >= min(PAGE_SIZE, n_users) else f"API CAPS PAGES AT {got} (handled; more requests)"))

    # Check 2: modified__gte filter on /count/ — REQUIRED
    try:
        c = api.count("/inspection/job/", {"modified__gte": since})
        lines.append(f"2. /inspection/job/count/?modified__gte: OK ({c} jobs modified in {MODIFIED_MAX_DAYS} days)")
    except SbnError as e:
        raise SbnError(f"2. /inspection/job/count/?modified__gte FAILED ({e}); daily runs would fail. "
                       "Results so far: " + " | ".join(lines))

    # Check 3: reopened jobs have a later modified date
    jobs = api.paginate("/inspection/job/", {"modified__gte": since})
    reopened = [j for j in jobs if j.get("job_status") != "completed" and j.get("completion_date")]
    if not reopened:
        lines.append("3. Reopened jobs: none found in 30 days; can't confirm from data (ask SBN)")
    else:
        later = sum(1 for j in reopened if (j.get("modified") or "") >= j["completion_date"])
        lines.append(f"3. Reopened jobs: {len(reopened)}, modified on/after completion: {later}: "
                     + ("consistent with reopening updating the modified date" if later == len(reopened)
                        else "SOME were NOT modified after completion; check with SBN"))
    return " | ".join(lines)


# =============================================================================
# STORED PROCEDURE ENTRY POINT (sbn_ingest_sproc_warehouse only)
# This is called by Snowflake when you run: CALL SBN_REFRESH()
# It reads the secret using _snowflake (the stored procedure's secret API,
# different from the Code Bundle's sf_secrets API), then calls run() above.
# sbn_daily.py does NOT call main() — it calls run() directly.
# =============================================================================
def main(session, days_back=30, mode="load") -> str:
    import _snowflake   # only available inside a Snowflake stored procedure
    cred = _snowflake.get_username_password("cred")   # 'cred' is the alias set in the SECRETS clause
    return run(session, int(days_back), str(mode).lower(), DEFAULT_BASE_URL, cred.username, cred.password)
