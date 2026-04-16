#!/usr/bin/env python
"""Sets up all parameters for the Linux runfile installer workflow. Primarily used to get pull tag, pull run id and ROCm version information of the latest nightly build from https://rocm.nightlies.amd.com/deb/ and https://rocm.nightlies.amd.com/rpm/ (using today's date) if user hasn't already defined pull_tag and pull_run_id.

This script handles:
1. Reading workflow inputs from command-line arguments
2. Auto-detecting pull_run_id and pull_tag from latest nightly build if BOTH are not provided.
3. Auto-detecting GFX architectures if gfx_archs is "all", otherwise use gfx arch that user passes in.

Command-line arguments:
    --rocm-version: ROCm version (optional, reads from index.html file from latest nightly build.)
    --gfx-archs: GFX architectures to build ("all" for auto-detect)
    --pull-amdgpu: Version of amdgpu to package (optional, auto-detects latest released amdgpu from instinct docs)
    --pull-tag: Build date in YYYYMMDD format (optional, defaults to today)
    --pull-run-id: Workflow run ID (optional, auto-detected if empty)
    --pull-pkg: Base package name

Outputs written to GITHUB_OUTPUT:
    * rocm_version: The ROCm version of the nightly build of ROCm packages.
    * gfx_archs: GFX architectures (comma-separated)
    * pull_amdgpu: AMDGPU version
    * pull_pkg: Package name
    * pull_tag: Build date in YYYYMMDD format
    * pull_run_id: GitHub Actions run ID of the nightly build of ROCm packages.

Example usage:
    python setup_runfile_installer.py --rocm-version 7.12.0 --gfx-archs all --pull-pkg amdrocm-core-sdk
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from github_actions_utils import gha_set_output, gha_append_step_summary

NIGHTLY_BASE_URL = "https://rocm.nightlies.amd.com"


def fetch_index(url: str, retries: int = 3) -> str:
    """Fetch HTML content from URL.

    Args:
        url: The URL to fetch
        retries: Number of retry attempts on failure
    """
    print(f"Fetching {url}")
    for attempt in range(retries):
        try:
            with urlopen(url, timeout=30) as response:
                return response.read().decode("utf-8")
        except (HTTPError, URLError) as e:
            print(f"Error fetching {url} (attempt {attempt + 1}/{retries}): {e}")
            if attempt + 1 >= retries:
                raise


def extract_folders(html: str, date_prefix: str) -> set[str]:
    """Extract folder names matching YYYYMMDD-RUNID pattern."""
    pattern = rf"({date_prefix}-\d+)"
    matches = re.findall(pattern, html)
    return set(matches)


def find_common_latest(rpm_folders: set[str], deb_folders: set[str]) -> str | None:
    """Find the latest folder that exists in both sets."""
    common = rpm_folders & deb_folders
    if not common:
        return None
    # Sort by run ID (numeric) and return highest
    return max(common, key=lambda x: int(x.split("-")[1]))


def extract_gfx_archs(html: str, package_prefix: str = "amdrocm-core-sdk-") -> set[str]:
    """Extract GFX architecture names from package index HTML."""
    pattern = rf"{package_prefix}(gfx[a-z0-9]+)[_-]"
    matches = re.findall(pattern, html, re.IGNORECASE)
    return set(matches)


def version_sort_key(gfx: str):
    """Sort key for GFX architecture names with proper version ordering.

    Handles names like gfx90a, gfx942, gfx1100, gfx1150 correctly.
    Extracts numeric parts and sorts numerically.
    """
    parts = re.findall(r"(\d+|[a-zA-Z]+)", gfx)
    result = []
    for part in parts:
        if part.isdigit():
            result.append((0, int(part)))  # Numbers sort first, by value
        else:
            result.append((1, part))  # Letters sort after, alphabetically
    return result


def fetch_nightly_run_id(pull_tag: str) -> tuple[str, str]:
    """Fetch the latest nightly run ID for the given date.

    Returns:
        Tuple of (pull_run_id, pull_tag)
    """
    print(f"Fetching nightly indexes for {pull_tag}...")

    rpm_html = fetch_index(url=f"{NIGHTLY_BASE_URL}/rpm/")
    deb_html = fetch_index(url=f"{NIGHTLY_BASE_URL}/deb/")

    print(f"deb_html:\n{deb_html}")

    rpm_folders = extract_folders(html=rpm_html, date_prefix=pull_tag)
    deb_folders = extract_folders(html=deb_html, date_prefix=pull_tag)

    print(f"RPM folders: {sorted(rpm_folders)}")
    print(f"DEB folders: {sorted(deb_folders)}")

    latest = find_common_latest(rpm_folders=rpm_folders, deb_folders=deb_folders)
    if not latest:
        print(f"ERROR: No matching folders for {pull_tag} in both rpm and deb")
        sys.exit(1)

    pull_run_id = latest.split("-")[1]
    print(f"Found latest: {latest} (pull_run_id={pull_run_id})")

    return pull_run_id, pull_tag


def fetch_rocm_version(pull_tag: str, pull_run_id: str) -> str:
    """Detect ROCm version from nightly package index.

    Looks for packages with the given pull_run_id and extracts the version.
    Example package name: amdrocm-amdsmi_7.12.0~pre1-23340740363_amd64.deb
    The version is 7.12.0 (extracted from _X.Y.Z~preN-RUNID_)

    Returns:
        ROCm version string (e.g., "7.12.0")
    """
    print(f"Detecting ROCm version for pull_run_id={pull_run_id}...")

    folder = f"{pull_tag}-{pull_run_id}"
    deb_pkg_url = f"{NIGHTLY_BASE_URL}/deb/{folder}/pool/main/index.html"

    try:
        html = fetch_index(url=deb_pkg_url)
    except (HTTPError, URLError) as e:
        print(f"ERROR: Failed to fetch package index: {e}")
        sys.exit(1)

    # Match pattern: _X.Y.Z~[PULL_TAG]-[RUNID]_ where PULL_TAG and RUNID matches the provided pull_tag and pull_run_id respectively.
    # Example: amdrocm-core-sdk-gfx950_7.13.0~20260406-24019412486_amd64.deb
    # Pattern: 7.13.0~20260406-24019412486_
    pattern = rf"_(\d+\.\d+\.\d+)~{pull_tag}-{pull_run_id}_"
    match = re.search(pattern=pattern, string=html)

    if not match:
        print(f"ERROR: Could not find ROCm version for pull_run_id={pull_run_id}")
        sys.exit(1)

    rocm_version = match.group(1)
    print(f"Detected ROCm version: {rocm_version}")

    return rocm_version


def fetch_gfx_archs(pull_tag: str, pull_run_id: str) -> str:
    """Detect common GFX architectures from nightly package indexes.

    Returns:
        Comma-separated list of GFX architectures
    """
    print("Detecting GFX architectures...")

    folder = f"{pull_tag}-{pull_run_id}"
    deb_pkg_url = f"{NIGHTLY_BASE_URL}/deb/{folder}/pool/main/index.html"
    rpm_pkg_url = f"{NIGHTLY_BASE_URL}/rpm/{folder}/x86_64/index.html"

    try:
        deb_pkg_html = fetch_index(url=deb_pkg_url)
        rpm_pkg_html = fetch_index(url=rpm_pkg_url)
    except (HTTPError, URLError) as e:
        print(f"ERROR: Failed to fetch package indexes: {e}")
        sys.exit(1)

    deb_gfx = extract_gfx_archs(html=deb_pkg_html)
    rpm_gfx = extract_gfx_archs(html=rpm_pkg_html)

    deb_gfx = sorted(deb_gfx, key=version_sort_key)
    rpm_gfx = sorted(rpm_gfx, key=version_sort_key)

    if deb_gfx != rpm_gfx:
        print("ERROR: Different GFX architectures for deb and rpm packages")
        print(f"deb GFX architectures: {deb_gfx}")
        print(f"rpm GFX architectures: {rpm_gfx}")
        sys.exit(1)

    gfx_archs = ",".join(sorted(deb_gfx, key=version_sort_key))
    print(f"Common GFX architectures: {gfx_archs}")

    return gfx_archs


def get_amdgpu_driver_version() -> str | None:
    """Fetch the latest AMDGPU driver version from AMD docs."""
    url = "https://instinct.docs.amd.com/projects/amdgpu-docs/en/latest/"

    amdgpu_html = fetch_index(url=url)

    # Find line containing 'AMD GPU Driver (amdgpu)' and extract version
    match = re.search(
        pattern=r"AMD GPU Driver \(amdgpu\).*?(\d+\.\d+\.\d+)", string=amdgpu_html
    )
    if match:
        latest_released_amdgpu = match.group(1)
        print(f"Latest released AMDGPU driver: {latest_released_amdgpu}")
        return f"release,{latest_released_amdgpu}"
    print(
        f"ERROR: Unable to auto-detect the latest release version of the amdgpu driver here: {url}"
    )
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Setup parameters for Linux runfile installer workflow"
    )

    parser.add_argument(
        "--gfx-archs",
        default="",
        help="GFX architectures to build ('all' for auto-detect)",
    )
    parser.add_argument(
        "--pull-amdgpu", default="", help="Version of amdgpu to package"
    )
    parser.add_argument(
        "--pull-tag",
        default="",
        help="Build date in YYYYMMDD format (defaults to today)",
    )
    parser.add_argument(
        "--pull-run-id", default="", help="Workflow run ID (auto-detected if empty)"
    )
    parser.add_argument("--pull-pkg", default="", help="Base package name")

    args = parser.parse_args()

    # Read from command-line arguments
    gfx_archs = args.gfx_archs
    pull_amdgpu = args.pull_amdgpu
    pull_tag = args.pull_tag
    pull_run_id = args.pull_run_id
    pull_pkg = args.pull_pkg

    outputs = {}
    sources = {}

    # Track provided values
    print(f"Using PULL_PKG={pull_pkg}")
    sources["pull_pkg"] = "provided"

    # Auto-detect pull_run_id and pull_tag if needed
    if pull_run_id and pull_tag:
        print(f"Using provided PULL_RUN_ID={pull_run_id}")
        print(f"Using provided PULL_TAG={pull_tag}")
        sources["pull_run_id"] = "provided"
        sources["pull_tag"] = "provided"
    else:
        # Use provided pull_tag or default to today
        if not pull_tag:
            pull_tag = datetime.now(timezone.utc).strftime("%Y%m%d")
            print(f"Using today's date as PULL_TAG={pull_tag}")
            sources["pull_tag"] = "today's date"
        else:
            sources["pull_tag"] = "provided"
        pull_run_id, pull_tag = fetch_nightly_run_id(pull_tag=pull_tag)
        print(f"Auto-detected PULL_RUN_ID={pull_run_id}, PULL_TAG={pull_tag}")
        sources["pull_run_id"] = "auto-detected"

    # Handle gfx_archs
    if gfx_archs == "all":
        gfx_archs = fetch_gfx_archs(pull_tag=pull_tag, pull_run_id=pull_run_id)
        sources["gfx_archs"] = "auto-detected"
    else:
        print(f"Using provided GFX_ARCHS={gfx_archs}")
        sources["gfx_archs"] = "provided"

    rocm_version = fetch_rocm_version(pull_tag=pull_tag, pull_run_id=pull_run_id)
    print(f"Auto-detected ROCM_VERSION={rocm_version}")
    sources["rocm_version"] = "auto-detected"

    # If set to 'latest', then we get the version number of latest released version of amdgpu
    if pull_amdgpu == "latest":
        pull_amdgpu = get_amdgpu_driver_version()
        print(f"Auto-detected PULL_AMDGPU={pull_amdgpu}")
        sources["pull_amdgpu"] = "auto-detected"
    else:
        print(f"Using provided PULL_AMDGPU={pull_amdgpu}")
        sources["pull_amdgpu"] = "provided"

    outputs["gfx_archs"] = gfx_archs
    outputs["pull_run_id"] = pull_run_id
    outputs["pull_tag"] = pull_tag
    outputs["pull_amdgpu"] = pull_amdgpu
    outputs["pull_pkg"] = pull_pkg
    outputs["rocm_version"] = rocm_version

    # Write all outputs
    gha_set_output(outputs)

    # Write prettified summary
    summary = f"""## Runfile Installer Setup Complete

<details>
<summary>Build Parameters</summary>

| Parameter | Value | Source |
|-----------|-------|--------|
| ROCM_VERSION | `{rocm_version}` | {sources["rocm_version"]} |
| PULL_TAG | `{pull_tag}` | {sources["pull_tag"]} |
| PULL_RUN_ID | `{pull_run_id}` | {sources["pull_run_id"]} |
| GFX_ARCHS | `{gfx_archs}` | {sources["gfx_archs"]} |
| PULL_AMDGPU | `{pull_amdgpu}` | {sources["pull_amdgpu"]} |
| PULL_PKG | `{pull_pkg}` | {sources["pull_pkg"]} |

</details>
"""
    gha_append_step_summary(summary)


if __name__ == "__main__":
    main()
