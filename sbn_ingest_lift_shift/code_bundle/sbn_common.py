"""Shared core for the SBN Completed Inspections notebooks (AIL-1683).

Imported by both ``SBN_Completed_Inspections_Daily.ipynb`` and
``SBN_Completed_Inspections_Backfill.ipynb`` so the auth, fetch, transform and
upsert logic lives in exactly one place (no inline-copy drift).

Design notes — see docs/plans/2026-06-22-feat-sbn-completed-inspections-api-notebook-plan.md

- **Auth:** session login — ``POST /core/user/login/`` (username/password) →
  ``Authorization: session <id>`` header on every subsequent call.
- **Fetch:** keyset pagination (``ordering=id&id__gt=<last>``) — immune to the
  offset-drift skip/dup that a mutating table causes. Confirmed working live.
- **Completeness gate:** ``/job/count/`` taken before AND after the sweep;
  assert ``unique_ids >= max(before, after)`` or abort (never write a partial
  pull — that is the exact bug this project replaces).
- **Transform:** ``location_hierarchy`` is a ``~``-delimited string → fixed
  ``Location Lv1..Lv10`` columns. FK ids (checklist / users) resolved via small
  lookup maps (510 users, 107 checklists — full pagination is cheap).
- **Upsert:** read existing → concat(fresh AFTER existing) → sort by modified
  (NaT first, stable) → drop_duplicates(id, keep=last) → REPLACE. No native Domo
  upsert key; done in pandas. Never drops rows outside the fetch window.

This module imports ONLY stdlib + requests + pandas so it is unit-testable
locally without ``domojupyter`` (which only exists inside the Domo Workspace).
Domo dataset read/write stays in the notebook cells.
"""
from __future__ import annotations

import logging
import time
from datetime import date, datetime, timedelta, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple

import pandas as pd
import requests
from requests.adapters import HTTPAdapter

try:  # urllib3 lives under requests' vendored namespace on some images
    from urllib3.util.retry import Retry
except Exception:  # pragma: no cover
    from requests.packages.urllib3.util.retry import Retry  # type: ignore

# --------------------------------------------------------------------------- #
# Logging + token redaction (Domo persists cell outputs into the saved
# notebook, so a stray session id in a log line would get committed).
# --------------------------------------------------------------------------- #
log = logging.getLogger("sbn_inspections")
log.setLevel(logging.INFO)
if not log.handlers:
    _h = logging.StreamHandler()
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(_h)
    log.propagate = False


class TokenRedactor(logging.Filter):
    """Scrub live session-id values from log records before they hit output."""

    MIN_LEN = 8

    def __init__(self) -> None:
        super().__init__()
        self._secrets: set[str] = set()

    def add(self, *values: Optional[str]) -> None:
        for v in values:
            if v and isinstance(v, str) and len(v) >= self.MIN_LEN:
                self._secrets.add(v)

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        for s in self._secrets:
            if s in msg:
                msg = msg.replace(s, "***REDACTED***")
        record.msg = msg
        record.args = ()
        return True


redactor = TokenRedactor()
for _h in log.handlers:
    _h.addFilter(redactor)
logging.getLogger().addFilter(redactor)


class TransportError(Exception):
    """Raised after exhausting retries, or on a non-recoverable HTTP error."""


class CompletenessError(Exception):
    """Raised when the fetched row count is short of the API count — a drop."""


# --------------------------------------------------------------------------- #
# Schema — output columns match the existing "Completed Inspections by
# Checklist" CSV exactly, so downstream cards repoint with no rework.
# --------------------------------------------------------------------------- #
LOCATION_LEVELS = 10
LOCATION_COLUMNS = [f"Location Lv{i}" for i in range(1, LOCATION_LEVELS + 1)]

REPORT_COLUMNS: List[str] = [
    "id",
    "Created Date",
    "Job Started Date",
    "Last Modified Date",
    "Completion Date",
    "Start Date",
    "Due Date",
    "Submission Status",
    "Inspection Status",
    "Checklist Name",
    "Creator First Name",
    "Creator Last Name",
    "Last Modified By First Name",
    "Last Modified By Last Name",
    "Owner First Name",
    "Owner Last Name",
    "Inspector First Name",
    "Inspector Last Name",
    "Frequency",
    "Workflow Status",
    "Comment",
    "Location Barcode Scanned",
    *LOCATION_COLUMNS,
]

# id is the upsert key; "Last Modified Date" is the recency tie-breaker.
DATETIME_COLUMNS = [
    "Created Date",
    "Job Started Date",
    "Last Modified Date",
    "Completion Date",
    "Start Date",
    "Due Date",
]
STRING_COLUMNS = [c for c in REPORT_COLUMNS if c not in DATETIME_COLUMNS and c != "id"]

ID_KEY = "id"
RECENCY_KEY = "Last Modified Date"

DEFAULT_BASE_URL = "https://wks.simplebutneeded.net/api/v1"
DEFAULT_PAGE_SIZE = 500
DEFAULT_TIMEOUT = (5, 35)  # read timeout sits ABOVE the API's 30s server timeout


# --------------------------------------------------------------------------- #
# Auth + HTTP
# --------------------------------------------------------------------------- #
def make_session() -> requests.Session:
    """requests.Session with adapter-level retry/backoff for transient errors."""
    s = requests.Session()
    retry = Retry(
        total=5,
        backoff_factor=0.5,
        status_forcelist=[429, 500, 502, 503, 504],
        respect_retry_after_header=True,
        raise_on_status=False,
        # GET is in the default allowed methods for both urllib3 1.26 and 2.x,
        # so we don't set allowed_methods/method_whitelist (avoids the version split).
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s


def _require_https(url: str) -> None:
    if not url.startswith("https://"):
        raise ValueError(f"Base URL must use HTTPS, got: {url!r}")


def login(session: requests.Session, base_url: str, username: str, password: str) -> str:
    """Authenticate and return the session id; sets the Authorization header.

    SBN docs: POST /core/user/login/ with username+password, then use either the
    ``sessionid`` cookie or ``Authorization: session <id>``. We use the header.
    """
    _require_https(base_url)
    resp = session.post(
        f"{base_url}/core/user/login/",
        data={"username": username, "password": password},
        timeout=DEFAULT_TIMEOUT,
    )
    if not resp.ok:
        raise TransportError(f"login: HTTP {resp.status_code}")
    # Django session auth: the `sessionid` cookie IS the session token. The login
    # response body's top-level `id` is the USER id (not the session) — never use it,
    # or `Authorization: session <user-id>` 403s on every subsequent call.
    sid: Optional[str] = session.cookies.get("sessionid")
    if not sid:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if isinstance(body, dict):
            sess = body.get("session")
            if isinstance(sess, dict):
                sid = sess.get("id") or sess.get("key")
            elif isinstance(sess, str):
                sid = sess
            sid = sid or body.get("sessionid") or body.get("key")
    if not sid:
        raise TransportError(
            "login succeeded but no session token found — 'sessionid' cookie absent and "
            f"no session field in body. Cookies seen: {list(session.cookies.keys())}"
        )
    sid = str(sid)
    redactor.add(sid)
    session.headers.update({"Authorization": f"session {sid}", "Accept": "application/json"})
    log.info("Authenticated to SBN as %s", username)
    return sid


def sbn_get(
    session: requests.Session,
    url: str,
    params: Optional[Dict[str, Any]] = None,
    *,
    relogin: Optional[Callable[[], None]] = None,
    max_relogin: int = 1,
) -> Dict[str, Any]:
    """GET returning parsed JSON. Adapter handles 429/5xx/network retries;
    this layer handles a single re-login on 401 (token expiry mid-run)."""
    relogged = 0
    while True:
        resp = session.get(url, params=params, timeout=DEFAULT_TIMEOUT)
        if resp.status_code == 401 and relogin and relogged < max_relogin:
            log.info("401 — re-authenticating once and retrying")
            relogin()
            relogged += 1
            continue
        if not resp.ok:
            raise TransportError(f"GET {url}: HTTP {resp.status_code}")
        return resp.json() if resp.text else {}


# --------------------------------------------------------------------------- #
# Fetch — keyset pagination + completeness gate
# --------------------------------------------------------------------------- #
def get_count(session, base_url, resource, filters, *, relogin=None) -> int:
    """Return the API's own count for a filtered resource (the gate baseline)."""
    data = sbn_get(session, f"{base_url}/inspection/{resource}/count/", dict(filters), relogin=relogin)
    return int(data.get("count", 0))


def paginate(
    session: requests.Session,
    base_url: str,
    resource: str,
    filters: Dict[str, Any],
    *,
    page_size: int = DEFAULT_PAGE_SIZE,
    relogin: Optional[Callable[[], None]] = None,
) -> List[Dict[str, Any]]:
    """Keyset-paginate an inspection resource by id (drift-immune).

    Dedups by id in-flight so an overlapping page can never yield a duplicate.
    """
    by_id: Dict[Any, Dict[str, Any]] = {}
    last_id = 0
    url = f"{base_url}/inspection/{resource}/"
    while True:
        params = {**filters, "ordering": "id", "id__gt": last_id, "limit": page_size}
        data = sbn_get(session, url, params, relogin=relogin)
        results = data.get("results", [])
        if not results:
            break
        for row in results:
            by_id[row["id"]] = row
        last_id = results[-1]["id"]
        if len(results) < page_size:
            break
    return list(by_id.values())


def fetch_completed_jobs(
    session: requests.Session,
    base_url: str,
    *,
    completion_gte: Optional[str] = None,
    completion_lt: Optional[str] = None,
    page_size: int = DEFAULT_PAGE_SIZE,
    relogin: Optional[Callable[[], None]] = None,
) -> List[Dict[str, Any]]:
    """Fetch completed jobs in a completion-date window, with a before/after
    count gate. Raises CompletenessError if the sweep came up short (a drop)."""
    filters: Dict[str, Any] = {"job_status": "completed"}
    if completion_gte:
        filters["completion_date__gte"] = completion_gte
    if completion_lt:
        filters["completion_date__lt"] = completion_lt

    count_before = get_count(session, base_url, "job", filters, relogin=relogin)
    jobs = paginate(session, base_url, "job", filters, page_size=page_size, relogin=relogin)
    count_after = get_count(session, base_url, "job", filters, relogin=relogin)

    expected = max(count_before, count_after)
    if len(jobs) < expected:
        raise CompletenessError(
            f"completed-window fetch short: got {len(jobs)} unique jobs, "
            f"API count {expected} (before={count_before}, after={count_after}). Aborting without write."
        )
    log.info("Fetched %d completed jobs (API count before=%d after=%d)", len(jobs), count_before, count_after)
    return jobs


def fetch_recently_modified(
    session: requests.Session,
    base_url: str,
    *,
    modified_gte: str,
    page_size: int = DEFAULT_PAGE_SIZE,
    relogin: Optional[Callable[[], None]] = None,
) -> List[Dict[str, Any]]:
    """Fetch jobs modified since a cutoff, WITHOUT the completed filter, so
    edits and status reversions to already-landed jobs are observable."""
    filters = {"modified__gte": modified_gte}
    jobs = paginate(session, base_url, "job", filters, page_size=page_size, relogin=relogin)
    log.info("Fetched %d recently-modified jobs (modified >= %s)", len(jobs), modified_gte)
    return jobs


def build_lookup_map(
    session: requests.Session,
    base_url: str,
    resource: str,
    value_fn: Callable[[Dict[str, Any]], Any],
    *,
    core: bool = False,
    relogin: Optional[Callable[[], None]] = None,
    page_size: int = DEFAULT_PAGE_SIZE,
) -> Dict[Any, Any]:
    """Fully paginate a small lookup resource into an {id: value} map.

    ``core=True`` targets ``/core/<resource>/`` (users); otherwise
    ``/inspection/<resource>/`` (checklists). Both are tiny (≤510 rows)."""
    prefix = "core" if core else "inspection"
    url = f"{base_url}/{prefix}/{resource}/"
    out: Dict[Any, Any] = {}
    last_id = 0
    expected = sbn_get(session, f"{url}count/", relogin=relogin).get("count")
    while True:
        data = sbn_get(session, url, {"ordering": "id", "id__gt": last_id, "limit": page_size}, relogin=relogin)
        results = data.get("results", [])
        if not results:
            break
        for row in results:
            out[row["id"]] = value_fn(row)
        last_id = results[-1]["id"]
        if len(results) < page_size:
            break
    if expected is not None and len(out) < int(expected):
        raise CompletenessError(
            f"{resource} lookup map short: got {len(out)}, API count {expected}. "
            "Names would be silently partial — aborting."
        )
    log.info("Built %s lookup map: %d entries", resource, len(out))
    return out


# --------------------------------------------------------------------------- #
# Transform — pure functions (unit-tested locally)
# --------------------------------------------------------------------------- #
def split_location_levels(hierarchy: Optional[str]) -> List[Optional[str]]:
    """Split a ``~``-delimited location hierarchy into exactly LOCATION_LEVELS
    parts, null-padded. >10 levels: extras are joined into the last column so
    no data is silently dropped or shifted."""
    out: List[Optional[str]] = [None] * LOCATION_LEVELS
    if hierarchy is None or (isinstance(hierarchy, float) and pd.isna(hierarchy)):
        return out
    parts = [p.strip() for p in str(hierarchy).split("~")]
    if len(parts) > LOCATION_LEVELS:
        log.warning("location_hierarchy has %d levels (>%d); joining overflow into last column: %r",
                    len(parts), LOCATION_LEVELS, hierarchy)
        parts = parts[: LOCATION_LEVELS - 1] + ["~".join(parts[LOCATION_LEVELS - 1:])]
    for i, val in enumerate(parts):
        out[i] = val if val != "" else None
    return out


def resolve_name(user_map: Dict[Any, Tuple[str, str]], fk_id: Any) -> Tuple[str, str]:
    """(first, last) for a user FK. Absent FK → ('', ''); present-but-unresolved
    → ('user#<id>', '') so the row is never dropped or silently blanked."""
    if fk_id is None or (isinstance(fk_id, float) and pd.isna(fk_id)):
        return "", ""
    if fk_id in user_map:
        return user_map[fk_id]
    return f"user#{fk_id}", ""


def resolve_checklist(checklist_map: Dict[Any, str], fk_id: Any) -> str:
    if fk_id is None or (isinstance(fk_id, float) and pd.isna(fk_id)):
        return ""
    return checklist_map.get(fk_id, f"checklist#{fk_id}")


def job_to_report_row(
    job: Dict[str, Any],
    checklist_map: Dict[Any, str],
    user_map: Dict[Any, Tuple[str, str]],
) -> Dict[str, Any]:
    """Map one raw /job/ record to the report-shaped row (pure)."""
    creator_f, creator_l = resolve_name(user_map, job.get("created_by"))
    mod_f, mod_l = resolve_name(user_map, job.get("modified_by"))
    owner_f, owner_l = resolve_name(user_map, job.get("owner"))
    insp_f, insp_l = resolve_name(user_map, job.get("inspector"))
    levels = split_location_levels(job.get("location_hierarchy"))

    row: Dict[str, Any] = {
        "id": job.get("id"),
        "Created Date": job.get("created"),
        "Job Started Date": job.get("job_started"),
        "Last Modified Date": job.get("modified"),
        "Completion Date": job.get("completion_date"),
        "Start Date": job.get("start_date"),
        "Due Date": job.get("due_date"),
        "Submission Status": job.get("submission_status"),
        "Inspection Status": job.get("job_status"),
        "Checklist Name": resolve_checklist(checklist_map, job.get("checklist")),
        "Creator First Name": creator_f,
        "Creator Last Name": creator_l,
        "Last Modified By First Name": mod_f,
        "Last Modified By Last Name": mod_l,
        "Owner First Name": owner_f,
        "Owner Last Name": owner_l,
        "Inspector First Name": insp_f,
        "Inspector Last Name": insp_l,
        "Frequency": job.get("frequency"),
        "Workflow Status": job.get("workflow_status"),
        "Comment": job.get("comment"),
        "Location Barcode Scanned": job.get("location_barcode_scanned"),
    }
    for col, val in zip(LOCATION_COLUMNS, levels):
        row[col] = val
    return row


def build_report_frame(
    jobs: List[Dict[str, Any]],
    checklist_map: Dict[Any, str],
    user_map: Dict[Any, Tuple[str, str]],
) -> pd.DataFrame:
    """Build a schema-cast, report-shaped DataFrame from raw job records."""
    rows = [job_to_report_row(j, checklist_map, user_map) for j in jobs]
    df = pd.DataFrame(rows, columns=REPORT_COLUMNS)
    return cast_schema(df)


def _to_naive_utc(series: pd.Series) -> pd.Series:
    """Coerce a column (datetime64, or ISO strings with T/space separators and
    Z/+00:00/naive offsets) to naive-UTC datetime64[ns]. Stable across REPLACE
    round-trips so column dtypes never flip between runs."""
    if pd.api.types.is_datetime64_any_dtype(series):
        if getattr(series.dtype, "tz", None) is not None:
            series = series.dt.tz_convert("UTC").dt.tz_localize(None)
        return series.astype("datetime64[ns]")
    # format="mixed" infers per element → handles 'T'/space and Z/+00:00/naive.
    parsed = pd.to_datetime(series, utc=True, errors="coerce", format="mixed")
    return parsed.dt.tz_localize(None)


def cast_schema(df: pd.DataFrame) -> pd.DataFrame:
    """Coerce to the canonical schema/dtypes. Datetimes → naive UTC datetime64
    (tz-stripped) so REPLACE never flips column types between runs."""
    out = df.reindex(columns=REPORT_COLUMNS).copy()
    out["id"] = pd.to_numeric(out["id"], errors="coerce").astype("Int64")
    for col in DATETIME_COLUMNS:
        out[col] = _to_naive_utc(out[col])
    for col in STRING_COLUMNS:
        out[col] = out[col].astype("string")
    return out


def upsert_on_id(existing: pd.DataFrame, fresh: pd.DataFrame) -> pd.DataFrame:
    """Merge fresh into existing keyed on id, keeping the most-recently-modified
    row per id. Rows in existing that aren't in fresh are preserved unchanged.

    fresh is concatenated AFTER existing and the sort is stable, so equal
    "Last Modified Date" ties resolve to the fresh row. NaT recency sorts first
    (loses), so a real timestamp always beats a missing one.
    """
    existing = cast_schema(existing)
    fresh = cast_schema(fresh)
    merged = pd.concat([existing, fresh], ignore_index=True)
    # Coalesce a missing recency key to Created Date so the sort is well-defined.
    recency = merged[RECENCY_KEY].fillna(merged["Created Date"])
    merged = merged.assign(_recency=recency).sort_values(
        "_recency", na_position="first", kind="mergesort"
    )
    merged = merged.drop_duplicates(subset=[ID_KEY], keep="last").drop(columns=["_recency"])
    merged = merged.dropna(subset=[ID_KEY]).reset_index(drop=True)
    return cast_schema(merged)


# --------------------------------------------------------------------------- #
# Date-window helpers
# --------------------------------------------------------------------------- #
def iso_utc(d: date) -> str:
    """Midnight-UTC ISO8601 for a date — used as an inclusive lower bound."""
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc).isoformat()


def month_starts(start: date, end_inclusive: date) -> List[Tuple[date, date]]:
    """Yield (month_start, next_month_start) chunks covering [start, end]."""
    out: List[Tuple[date, date]] = []
    cur = date(start.year, start.month, 1)
    last = date(end_inclusive.year, end_inclusive.month, 1)
    while cur <= last:
        nxt = date(cur.year + 1, 1, 1) if cur.month == 12 else date(cur.year, cur.month + 1, 1)
        out.append((max(cur, start), nxt))
        cur = nxt
    return out


# --------------------------------------------------------------------------- #
# Reconciliation (AIL-1860) — prove a reload matches the SBN source of truth.
#
# The SBN CSV export stores "Completion Date" as UTC-7 wall-clock with NO tz
# marker (MM/DD/YYYY HH:MM:SS), whereas Domo stores DATETIME as UTC. To compare
# the CSV against Domo's stored value we add 7h to the CSV value. This +7h is
# ONLY for the CSV oracle — it is NEVER applied in the ingest pipeline, which
# reads tz-aware timestamps from the API and already lands correct UTC. A
# non-zero delta after a reload signals a timezone-convention regression to
# investigate BEFORE repointing downstream (see the AIL-1860 discovery + plan).
# --------------------------------------------------------------------------- #
COMPLETION_COL = "Completion Date"
SBN_CSV_COMPLETION_FORMAT = "%m/%d/%Y %H:%M:%S"
SBN_CSV_COMPLETION_OFFSET_HOURS = 7  # CSV is UTC-7; +7h -> UTC to match Domo storage


def parse_sbn_csv_completion_utc(series: pd.Series) -> pd.Series:
    """Parse the SBN CSV 'Completion Date' (UTC-7, no tz marker) to naive-UTC
    datetime64 by adding 7h, so it lines up with Domo's stored UTC value.
    Unparseable values become NaT (never silently shifted)."""
    naive = pd.to_datetime(series, format=SBN_CSV_COMPLETION_FORMAT, errors="coerce")
    return (naive + pd.Timedelta(hours=SBN_CSV_COMPLETION_OFFSET_HOURS)).astype("datetime64[ns]")


def reconcile_completion(
    domo_df: pd.DataFrame,
    sbn_df: pd.DataFrame,
    *,
    id_col: str = ID_KEY,
) -> pd.DataFrame:
    """Inner-join Domo (post-reload, UTC) against the SBN CSV (UTC via +7h) on id
    and return the per-id completion delta.

    Returns columns: id, domo_completion, sbn_completion_utc, delta_seconds.
    A correctly reloaded row has ``delta_seconds == 0``. Rows present in only one
    source are dropped (inner join); measure coverage separately with the raw
    id sets if that matters.
    """
    domo = pd.DataFrame({
        id_col: pd.to_numeric(domo_df[id_col], errors="coerce").astype("Int64"),
        "domo_completion": _to_naive_utc(domo_df[COMPLETION_COL]),
    }).dropna(subset=[id_col])
    sbn = pd.DataFrame({
        id_col: pd.to_numeric(sbn_df[id_col], errors="coerce").astype("Int64"),
        "sbn_completion_utc": parse_sbn_csv_completion_utc(sbn_df[COMPLETION_COL]),
    }).dropna(subset=[id_col])

    merged = domo.merge(sbn, on=id_col, how="inner")
    merged["delta_seconds"] = (
        merged["sbn_completion_utc"] - merged["domo_completion"]
    ).dt.total_seconds()
    return merged
