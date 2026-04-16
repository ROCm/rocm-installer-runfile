"""Utilities for working with GitHub Actions from Python.

See also https://pypi.org/project/github-action-utils/.

Copied from https://github.com/ROCm/TheRock/blob/main/build_tools/github_actions/github_actions_api.py
"""

import json
import os
from pathlib import Path
import sys
from typing import Mapping


def _log(*args, **kwargs):
    print(*args, **kwargs)
    sys.stdout.flush()


def gha_set_output(vars: Mapping[str, str | Path]):
    """Sets values in a step's output parameters.

    This appends to the file located at the $GITHUB_OUTPUT environment variable.

    See
      * https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions#setting-an-output-parameter
      * https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/passing-information-between-jobs
    """
    _log(f"Setting github output:\n{json.dumps(vars, indent=2)}")

    step_output_file = os.getenv("GITHUB_OUTPUT")
    if not step_output_file:
        _log("  Warning: GITHUB_OUTPUT env var not set, can't set github outputs")
        return

    with open(step_output_file, "a") as f:
        for k, v in vars.items():
            print(f"OUTPUT {k}={str(v)}")
            f.write(f"{k}={str(v)}\n")


def gha_append_step_summary(summary: str):
    """Appends a string to the GitHub Actions job summary.

    This appends to the file located at the $GITHUB_STEP_SUMMARY environment variable.

    See
      * https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions#adding-a-job-summary
      * https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#adding-a-job-summary
    """
    _log(f"Writing job summary:\n{summary}")

    step_summary_file = os.getenv("GITHUB_STEP_SUMMARY")
    if not step_summary_file:
        _log("  Warning: GITHUB_STEP_SUMMARY env var not set, can't write job summary")
        return

    with open(step_summary_file, "a") as f:
        # Use double newlines to split sections in markdown.
        f.write(summary + "\n\n")
