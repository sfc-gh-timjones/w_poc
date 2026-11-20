# =============================================================================
# backfill_seed.py  —  One-time history load for "SBN | Completed Inspections | RAW"
#
# PURPOSE
# -------
# The daily notebook (SBN_Completed_Inspections_Daily.ipynb) only pulls the
# last 30 days of completed inspections on each run. That means the very first
# time it runs, it would only have 30 days of history — everything older would
# be missing forever.
#
# This script is the fix: run it ONCE, before the daily notebook ever runs. It
# reaches back ~18 months (560 days by default) and loads the full history into
# the table. After that, the daily notebook takes over and keeps it fresh.
#
# HOW TO RUN
# ----------
# This is not an interactive script — it must be executed as a Code Bundle:
#   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'backfill_seed.py';
# Running it directly in Snowsight will fail (the environment variables and
# secret access only exist inside a Code Bundle execution).
#
# WHAT IT DOES
# ------------
# 1. Reads credentials from the Snowflake secret
# 2. Logs into the SBN API and builds lookup tables (checklists, users)
# 3. Loops month by month from BACKFILL_FROM to today, fetching all completed
#    inspections in each month
# 4. Writes the full history to the Snowflake table in one shot (REPLACE)
# 5. Saves the row count so the daily notebook's safety check has a baseline
#
# This is essentially the same logic as WKS's original Backfill notebook in
# Domo, rebuilt using only functions already in sbn_common.py.
# =============================================================================

import os, sys
from pathlib import Path
from datetime import date, timedelta


# =============================================================================
# SECTION 1: Standard library imports and path setup
# =============================================================================

# Make sbn_common.py importable. The Code Bundle puts all uploaded files in the
# same directory, so inserting the current working directory into Python's
# module search path lets us do "import sbn_common" on the next line.
sys.path.insert(0, str(Path.cwd()))

import pandas as pd           # data manipulation (DataFrames)
import sbn_common as sc       # WKS's own SBN API helper module (unchanged)


# =============================================================================
# SECTION 2: Snowflake port block — credentials and working directory
#
# In Domo, credentials live in a file called sbn.env in the workspace folder.
# In Snowflake, secrets are stored securely in the Snowflake secret store. This
# block is the only change from the Domo version: instead of reading sbn.env,
# we pull the same two values (username + password) from a Snowflake secret.
# The rest of the script is identical to how WKS's original backfill works.
# =============================================================================

# Snowflake provides this function for reading secrets stored in the account.
# The secret path comes from the SBN_SECRET_PATH env var, which is set in
# code_bundle.yml so it doesn't have to be hardcoded here.
from snowflake.snowpark.secrets import get_username_password
_sbn = get_username_password(os.environ["SBN_SECRET_PATH"])

# Put the credentials into environment variables so sbn_common.py can read
# them with os.getenv("SBN_USERNAME") and os.getenv("SBN_PASSWORD") exactly
# as it does in Domo. setdefault means we only set them if not already set.
os.environ.setdefault("SBN_USERNAME", _sbn.username)
os.environ.setdefault("SBN_PASSWORD", _sbn.password)

# The Code Bundle's own folder is read-only. The daily notebook writes a file
# called ./state/last_row_count.txt (used by its safety check) and that file
# needs to survive between runs — just like files in the Domo Workspace folder.
# The NOTEBOOK_STATE Snowflake stage is mounted at /mnt/sbn_state, so by
# changing into that directory, any file writes go to the stage and persist.
os.chdir("/mnt/sbn_state")


# =============================================================================
# SECTION 3: Configuration
# =============================================================================

# Import the domojupyter stand-in. This module makes write_dataframe() work in
# Snowflake the same way it does in Domo (see domojupyter.py for details).
import domojupyter as domo

# The SBN API base URL. Normally blank (uses the default from sbn_common.py),
# but can be overridden via the SBN_BASE_URL env var in code_bundle.yml.
BASE_URL = os.getenv("SBN_BASE_URL", sc.DEFAULT_BASE_URL)

# The name of the dataset/table to write into — must match the daily notebook.
DATASET_NAME = "SBN | Completed Inspections | RAW"
# DATASET_NAME = "SBN_COMPLETED_INSPECTIONS_RAW"  # Snowflake-friendly name: comment out the line above and uncomment this one; also change the table name in the notebook, 01b_create_table.sql, 03_initial_load.sql and 04_schedule_and_monitor.sql

# How far back to go. Default is 560 days (~18 months). Can be overridden by
# setting BACKFILL_DAYS in the Code Bundle spec if you need a different window.
BACKFILL_FROM = date.today() - timedelta(days=int(os.getenv("BACKFILL_DAYS", "560")))


# =============================================================================
# SECTION 4: Authenticate with the SBN API and build lookup maps
#
# The SBN API requires a login before any data can be fetched. We also build
# two lookup tables upfront:
#   - checklist_map: maps checklist ID → checklist name
#   - user_map: maps user ID → (first name, last name)
# These are used later when converting raw API records into report rows.
# =============================================================================

# Create a reusable HTTP session object (handles retries, timeouts, auth headers)
session = sc.make_session()

# Define a login function so we can re-login if the session expires mid-run
def _login():
    sc.login(session, BASE_URL, os.environ["SBN_USERNAME"], os.environ["SBN_PASSWORD"])

# Perform the initial login
_login()

# Fetch all checklists and build a dict: {checklist_id: checklist_name}
# relogin=_login means if the session expires during this call, it logs in again automatically
checklist_map = sc.build_lookup_map(
    session, BASE_URL, "checklist",
    lambda r: r.get("name"),      # for each checklist record, extract the name
    relogin=_login
)

# Fetch all users and build a dict: {user_id: ("First", "Last")}
# core=True means users are under /core/user/ not /inspection/user/
user_map = sc.build_lookup_map(
    session, BASE_URL, "user",
    lambda r: (r.get("first_name") or "", r.get("last_name") or ""),  # extract both name parts
    core=True,
    relogin=_login
)


# =============================================================================
# SECTION 5: Fetch completed inspections month by month
#
# Rather than asking the API for 18 months at once (which could be tens of
# thousands of records), we loop month by month. Each month is fetched
# separately, which keeps each API request small and also lets sbn_common.py's
# completeness check work: before and after each fetch it asks the API for the
# count, and if the numbers don't match it aborts rather than writing partial data.
# =============================================================================

frames = []  # will collect one DataFrame per month

# sc.month_starts returns a list of (start_date, end_date) pairs, one per calendar
# month from BACKFILL_FROM up to today. Example: [(2024-01-01, 2024-02-01), ...]
for lo, hi in sc.month_starts(BACKFILL_FROM, date.today()):

    # Fetch all completed jobs for this month from the SBN API
    jobs = sc.fetch_completed_jobs(
        session, BASE_URL,
        completion_gte=sc.iso_utc(lo),   # start of this month (UTC midnight)
        completion_lt=sc.iso_utc(hi),    # start of next month (UTC midnight)
        relogin=_login
    )

    # Convert the raw API records into a clean pandas DataFrame with the
    # exact column names and types that the report expects
    frames.append(sc.build_report_frame(jobs, checklist_map, user_map))

    # Print progress so you can see it working in the run output
    print(f"{lo:%Y-%m}: {len(jobs)} completed jobs")


# =============================================================================
# SECTION 6: Deduplicate and write the full history to Snowflake
# =============================================================================

# Combine all monthly DataFrames into one. upsert_on_id deduplicates by
# inspection ID, keeping the most recently modified version of each row in
# case the same inspection appeared in more than one month's pull.
# The first argument is an empty DataFrame (no existing data to merge into —
# this is the first ever load).
seeded = sc.upsert_on_id(pd.DataFrame(columns=sc.REPORT_COLUMNS), pd.concat(frames, ignore_index=True))

# Write the entire history to the Snowflake table using the domojupyter stand-in.
# update_method="REPLACE" means: create the table if it doesn't exist, or
# replace it entirely if it does. This is the same call the daily notebook makes.
domo.write_dataframe(seeded, DATASET_NAME, update_method="REPLACE")


# =============================================================================
# SECTION 7: Save the row count for the daily notebook's safety check
#
# The daily notebook reads ./state/last_row_count.txt before each run. If the
# existing table suddenly has 0 rows but the last known count was greater than 0,
# it treats that as a failed read and aborts rather than overwriting good history.
# We save the count here so that safety check has a baseline from day one.
# Because of the os.chdir call in Section 2 above, this file is written to the
# NOTEBOOK_STATE stage and will still be there when the daily notebook runs.
# =============================================================================

STATE = Path("./state")
STATE.mkdir(exist_ok=True)                                 # create ./state/ folder if needed
(STATE / "last_row_count.txt").write_text(str(len(seeded)))  # write the row count as plain text

print(f"✓ seeded {len(seeded):,} rows into '{DATASET_NAME}'")
