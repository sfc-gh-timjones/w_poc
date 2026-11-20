# =============================================================================
# sbn_daily.py  —  Code Bundle entrypoint (runs on a warehouse)
#
# WHAT IT DOES
# ------------
# This is the "front door" of the Code Bundle. When Snowflake runs:
#   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py'
# it starts here and runs top-to-bottom, like a script.
#
# This file's only job is wiring: read the arguments, read the SBN password,
# point the session at the right Snowflake schema, then hand off to
# sbn_refresh.py (which does all the actual API calls and database writes).
#
# Think of it like a main() that you'd call from the command line:
#   python sbn_daily.py --days-back 30
# except Snowflake is the one "calling" it, and the credentials come from a
# Snowflake secret instead of environment variables on your laptop.
#
# HOW TO RUN
#   USE WAREHOUSE INGESTION_WH;
#   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py';                           -- daily: last 30 days
#   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py' ARGUMENTS = ('--days-back','560');  -- history load
#   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py' ARGUMENTS = ('--mode','check');     -- API check only
# =============================================================================

# Standard Python libraries (always available; no install needed)
import os      # read environment variables set in code_bundle.yml
import sys     # read the ARGUMENTS list passed in EXECUTE CODE BUNDLE
from pathlib import Path   # find sbn_refresh.py on disk


# =============================================================================
# MAKE sbn_refresh.py IMPORTABLE
# The two files (sbn_daily.py and sbn_refresh.py) live in the same bundle
# folder. We tell Python where to look before we try to import it.
#
# Why the if-check?
#   On a warehouse, Python knows the script's file path (__file__ exists).
#   On a compute pool, the script runs like a notebook cell — Python doesn't
#   set __file__, so we fall back to the current working directory instead.
#   Both end up pointing at the same bundle folder.
# =============================================================================
_here = Path(__file__).resolve().parent if "__file__" in globals() else Path.cwd()
sys.path.insert(0, str(_here))
import sbn_refresh   # loads sbn_refresh.py from the same folder

# Snowflake-specific libraries (injected by Snowflake at run time)
from snowflake.snowpark.context import get_active_session   # the live database connection
from snowflake.snowpark import secrets as sf_secrets         # used to read the SBN password


# =============================================================================
# HELPER FUNCTION: read one ARGUMENTS flag value
# ARGUMENTS = ('--days-back', '30') lands in sys.argv as a list of strings.
# This finds the value that follows a named flag, or returns the default.
# Example: _arg('--days-back', '30') returns '30' if --days-back isn't set.
# =============================================================================
def _arg(name: str, default: str) -> str:
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


# =============================================================================
# HELPER FUNCTION: read the SBN username and password from a Snowflake secret.
#
# The secret is listed in code_bundle.yml under `secrets:`. Snowflake makes it
# available at run time, but the name you have to ask for depends on where the
# bundle is running (tested 2026-11-13):
#   warehouse    →  bare name:        SBN_CREDENTIALS
#   compute pool →  lowercase path:   wks_poc/sbn_ingest/sbn_credentials
# The full dotted name shown in Snowflake's docs failed on both — not a bug in
# this code, just a quirk of the Public Preview runtime.
#
# This function tries all three forms in order and returns the first one that
# works, so the same file runs on either compute type without changes.
# =============================================================================
def _credentials():
    full_name = os.environ["SBN_SECRET"]   # e.g. WKS_POC.SBN_INGEST.SBN_CREDENTIALS (from code_bundle.yml)
    candidates = (
        full_name.split(".")[-1],               # bare name:         SBN_CREDENTIALS
        full_name.lower().replace(".", "/"),     # lowercase path:    wks_poc/sbn_ingest/sbn_credentials
        full_name,                               # full dotted name:  WKS_POC.SBN_INGEST.SBN_CREDENTIALS
    )
    errors = []
    for name in candidates:
        try:
            return sf_secrets.get_username_password(name)   # returns an object with .username and .password
        except Exception as e:
            errors.append(f"{name}: {e}")
    raise RuntimeError("Could not read the SBN secret (is it listed under secrets: in code_bundle.yml?) "
                       + " | ".join(errors))


# =============================================================================
# MAIN SCRIPT — runs top-to-bottom when Snowflake executes this file.
# =============================================================================

# Step 1: Get the live Snowflake session that the warehouse injected for us,
# then point it at the right database and schema.
session = get_active_session()
session.sql(f'USE SCHEMA {os.environ["TARGET_DATABASE"]}.{os.environ["TARGET_SCHEMA"]}').collect()

# Step 2: Read the SBN username and password from the Snowflake secret.
cred = _credentials()

# Step 3: Hand off to sbn_refresh.run(). That function does everything:
#   - calls the SBN API (users, checklists, completed jobs, modified jobs)
#   - counts the results against the API's own counts
#   - writes / merges everything into SBN_JOBS_RAW, SBN_USERS_RAW, SBN_CHECKLISTS_RAW
#   - returns a one-line result string like "OK: ... 246 inserted, 99 updated"
result = sbn_refresh.run(
    session,
    days_back=int(_arg("--days-back", "30")),       # how far back to pull completed jobs (default 30 days)
    mode=_arg("--mode", "load"),                    # 'load' (default) or 'check' (read-only API check)
    base_url=os.getenv("SBN_BASE_URL", sbn_refresh.DEFAULT_BASE_URL),  # real SBN API unless overridden
    username=cred.username,
    password=cred.password,
)

# Step 4: Print the result — this is what shows up in
# Code Bundles > SBN_DAILY > Run history > Output
print(result)
