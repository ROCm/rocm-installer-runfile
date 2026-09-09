#!/usr/bin/env python
"""Sets up parameters for the Linux runfile installer CI workflow.

Fetches the latest stable ROCm version from the AMD stable package repository
and the latest released AMDGPU driver version.

Command-line arguments:
    --pull-amdgpu: Version of amdgpu to package (default: "latest" to auto-detect)

Outputs written to GITHUB_OUTPUT:
    * rocm_version: Latest stable ROCm version (e.g. "10.0.0")
    * pull_amdgpu: AMDGPU driver version (e.g. "release,31.50")
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).parent))

from github_actions_utils import gha_append_step_summary, gha_set_output

STABLE_DEB_INDEX_URL = (
    "https://stable.repo.amd.com/rocm/core/packages/deb/pool/main/index.html"
)


def fetch_index(url: str, retries: int = 3) -> str:
    print(f"Fetching {url}")
    for attempt in range(retries):
        try:
            with urlopen(url, timeout=30) as response:
                return response.read().decode("utf-8")
        except (HTTPError, URLError) as e:
            print(f"Error fetching {url} (attempt {attempt + 1}/{retries}): {e}")
            if attempt + 1 >= retries:
                raise


def rocm_version_tuple(version: str) -> tuple[int, ...]:
    """Convert a version string to a tuple for proper numeric sorting.

    Ensures 10.11.0 sorts after 10.2.0, unlike lexicographic ordering.
    """
    return tuple(int(x) for x in version.split("."))


def fetch_latest_rocm_version() -> str:
    """Fetch the latest stable ROCm version from the AMD package index.

    Parses package filenames like amdrocm-amdsmi_10.0.0-4_amd64.deb
    and returns the highest version using proper numeric sort.
    """
    html = fetch_index(STABLE_DEB_INDEX_URL)

    # Match _X.Y.Z-N_ in stable package filenames (e.g. _10.0.0-4_)
    matches = re.findall(r"_(\d+\.\d+\.\d+)-\d+_", html)
    if not matches:
        print("ERROR: Could not find any ROCm version in stable package index")
        sys.exit(1)

    versions = sorted(set(matches), key=rocm_version_tuple)
    latest = versions[-1]
    print(f"Available stable ROCm versions: {versions}")
    print(f"Latest stable ROCm version: {latest}")
    return latest



def get_amdgpu_driver_version() -> str:
    """Fetch the latest released AMDGPU driver version from AMD instinct docs."""
    url = "https://instinct.docs.amd.com/projects/amdgpu-docs/en/latest/"
    html = fetch_index(url)

    match = re.search(r"AMD GPU Driver \(amdgpu\).*?(\d+\.\d+\.\d+)", html)
    if not match:
        print(f"ERROR: Unable to auto-detect amdgpu driver version from {url}")
        sys.exit(1)

    version = match.group(1)
    print(f"Latest released AMDGPU driver: {version}")

    major, minor, patch = version.split(".")
    # Drop .0 patch — https://repo.radeon.com/amdgpu/ doesn't list patch versions ending in .0
    if patch == "0":
        version = f"{major}.{minor}"
        print(f"Dropped .0 patch suffix: {version}")

    return f"release,{version}"


def main():
    parser = argparse.ArgumentParser(
        description="Setup parameters for Linux runfile installer CI workflow"
    )
    parser.add_argument(
        "--pull-amdgpu",
        default="latest",
        help="AMDGPU driver version (default: 'latest' to auto-detect)",
    )

    args = parser.parse_args()

    pull_amdgpu = args.pull_amdgpu

    sources = {}

    rocm_version = fetch_latest_rocm_version()
    sources["rocm_version"] = "auto-detected"

    if pull_amdgpu == "latest":
        pull_amdgpu = get_amdgpu_driver_version()
        sources["pull_amdgpu"] = "auto-detected"
    else:
        print(f"Using provided PULL_AMDGPU={pull_amdgpu}")
        sources["pull_amdgpu"] = "provided"

    outputs = {
        "rocm_version": rocm_version,
        "pull_amdgpu": pull_amdgpu,
    }

    gha_set_output(outputs)

    summary = f"""## Runfile Installer CI Setup Complete

<details>
<summary>Build Parameters</summary>

| Parameter | Value | Source |
|-----------|-------|--------|
| ROCM_VERSION | `{rocm_version}` | {sources["rocm_version"]} |
| PULL_AMDGPU | `{pull_amdgpu}` | {sources["pull_amdgpu"]} |

</details>
"""
    gha_append_step_summary(summary)


if __name__ == "__main__":
    main()
