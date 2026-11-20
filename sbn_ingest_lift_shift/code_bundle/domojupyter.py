"""
domojupyter.py  —  Snowflake stand-in for Domo's domojupyter library
=====================================================================

WHY THIS FILE EXISTS
--------------------
In Domo, the notebook runs with a pre-installed library called `domojupyter`.
The notebook uses it in exactly two places:

    import domojupyter as domo
    ...
    existing = domo.read_dataframe(DATASET_NAME)      # read the whole dataset
    ...
    domo.write_dataframe(merged, DATASET_NAME, update_method="REPLACE")  # write it back

The `domojupyter` library is Domo-specific and doesn't exist outside of Domo.
If we just moved the notebook to Snowflake as-is, the `import domojupyter` line
would fail immediately with "No module named domojupyter".

Rather than rewriting the notebook's read/write calls (which would mean changes
to WKS's own code), we provide a file with the SAME NAME that implements the
SAME two functions. Python finds this file first when the notebook does
`import domojupyter`, so the notebook never knows it's running on Snowflake.

WHAT THE FUNCTIONS DO
---------------------
In Domo, datasets are named objects (e.g. "SBN | Completed Inspections | RAW").
Here, we map each dataset name to a Snowflake table with the exact same name,
in the database and schema set by the DOMO_DATABASE and DOMO_SCHEMA env vars
(configured in code_bundle.yml). The column names are also preserved, so
nothing downstream of the table needs to change.

WHAT WAS NOT CHANGED
--------------------
The notebook's code is identical to the Domo version. It still calls:
    domo.read_dataframe(DATASET_NAME)
    domo.write_dataframe(merged, DATASET_NAME, update_method="REPLACE")
This file is what makes those calls work in Snowflake.
"""
from __future__ import annotations

import os

import pandas as pd
from snowflake.snowpark.context import get_active_session  # Snowflake's way to get a DB connection


# ---------------------------------------------------------------------------
# Configuration: which Snowflake database and schema hold the "datasets"
# These values come from env vars set in code_bundle.yml so they don't
# need to be hardcoded here. DOMO_SCHEMA defaults to "DOMO" if not set,
# but code_bundle.yml sets it to SBN_LIFT_SHIFT.
# ---------------------------------------------------------------------------
DATABASE = os.getenv("DOMO_DATABASE", "WKS_POC")
SCHEMA   = os.getenv("DOMO_SCHEMA",   "DOMO")


def _table(dataset_name: str) -> str:
    """
    Build a fully-qualified Snowflake table name from a dataset name.

    Domo dataset names can contain spaces, pipes and other special characters
    (e.g. "SBN | Completed Inspections | RAW"). In Snowflake, any identifier
    with special characters must be wrapped in double quotes. This function
    handles that quoting, and also escapes any double quotes that might appear
    inside the name itself.

    Example:
        _table('SBN | Completed Inspections | RAW')
        → 'WKS_POC.SBN_LIFT_SHIFT."SBN | Completed Inspections | RAW"'
    """
    # Escape any embedded double quotes (replace " with "") then wrap in quotes
    return f'{DATABASE}.{SCHEMA}."{dataset_name.replace(chr(34), chr(34) * 2)}"'


def read_dataframe(dataset_name: str) -> pd.DataFrame:
    """
    Read an entire Snowflake table into a pandas DataFrame.

    This replaces domojupyter.read_dataframe() from Domo. The notebook calls
    this to read the existing dataset before merging in new rows.

    If the table doesn't exist yet, this raises an exception — which is
    intentional. The notebook's safety check catches that exception and
    aborts, preventing it from writing a partial pull over good history.
    That's exactly the same behavior as in Domo: the dataset must already
    exist (seeded by the Backfill notebook) before the daily notebook runs.
    """
    # get_active_session() returns the current Snowflake connection.
    # .table() references the table by name. .to_pandas() downloads all rows.
    return get_active_session().table(_table(dataset_name)).to_pandas()


def write_dataframe(df: pd.DataFrame, dataset_name: str, update_method: str = "REPLACE") -> None:
    """
    Write a pandas DataFrame to a Snowflake table.

    This replaces domojupyter.write_dataframe() from Domo. The notebook calls
    this after merging in the fresh rows to write the full combined dataset back.

    update_method="REPLACE" (the value the notebook always passes):
        Creates the table if it doesn't exist yet, or completely replaces it
        if it does. This matches Domo's REPLACE behavior: the whole dataset is
        rewritten on every run. History is preserved because the notebook reads
        the existing data first and merges it into the new write.

    update_method="APPEND":
        Adds rows to the existing table. Not used by this notebook, but
        implemented for completeness.
    """
    method = update_method.upper()
    if method not in ("REPLACE", "APPEND"):
        raise ValueError(f"Unsupported update_method {update_method!r}")

    get_active_session().write_pandas(
        df,                        # the DataFrame to write
        dataset_name,              # used as the Snowflake table name
        database=DATABASE,
        schema=SCHEMA,
        auto_create_table=True,    # create the table on the first run if it doesn't exist
        overwrite=(method == "REPLACE"),  # True for REPLACE = drop and recreate; False for APPEND
        quote_identifiers=True,    # preserve the exact column names (spaces, pipes, etc.)
        use_logical_type=True,     # write timestamps as TIMESTAMP_NTZ, not strings
    )
