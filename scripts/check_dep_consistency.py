#!/usr/bin/env python3
"""
Check for inconsistencies in package versions across build.act.json files.
Excludes local "stratoweave" dependencies (those with a "path" field).
"""

import json
import sys
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Tuple


def extract_dependencies(file_path: Path) -> Dict[str, Dict[str, str]]:
    """
    Extract external dependencies from a build.act.json file.
    Returns a dict of package_name -> {url, hash}.
    Excludes packages with "path" field (local dependencies like stratoweave).
    """
    try:
        with open(file_path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        print(f"Warning: Could not parse {file_path}: {e}", file=sys.stderr)
        return {}
    else:
        dependencies = {}
        for pkg_name, pkg_info in data.get("dependencies", {}).items():
            # Skip local dependencies (those with "path" field)
            if "path" in pkg_info:
                continue

            dependencies[pkg_name] = {
                "url": pkg_info.get("url", ""),
                "hash": pkg_info.get("hash", "")
            }

        return dependencies


def check_consistency(all_deps: Dict[Path, Dict[str, Dict[str, str]]]) -> Dict[str, List[Tuple[Path, str, str]]]:
    """
    Check for inconsistencies in package versions across files.
    Returns a dict of package_name -> list of (file_path, url, hash) tuples
    for packages that have inconsistent versions.
    """
    # Group by package name
    package_versions = defaultdict(list)

    for file_path, deps in all_deps.items():
        for pkg_name, pkg_info in deps.items():
            package_versions[pkg_name].append((file_path, pkg_info["url"], pkg_info["hash"]))

    # Return only packages with inconsistent versions
    return {
        pkg_name: versions
        for pkg_name, versions in package_versions.items()
        if len({(url, hash_val) for _, url, hash_val in versions}) > 1
    }


def print_report(inconsistent: Dict[str, List[Tuple[Path, str, str]]]) -> None:
    """Print a human-readable report of inconsistencies."""
    if not inconsistent:
        print("✓ All external dependencies are consistent across build.act.json files")
        return

    print("\n𐄂 Inconsistent package versions found:\n")

    for pkg_name, versions in sorted(inconsistent.items()):
        print(f"Package: {pkg_name}")

        # Group by version
        version_groups = defaultdict(list)
        for file_path, url, hash_val in versions:
            version_groups[(url, hash_val)].append(file_path)

        print(f"Found {len(version_groups)} different versions:")

        for (url, hash_val), file_paths in version_groups.items():
            print(f"  Version: {url}")
            print(f"    Hash: {hash_val}")
            print("    Used in:")
            for file_path in sorted(file_paths):
                print(f"      - {file_path}")
        print()
    print("Please update the inconsistent dependencies to use the same version (latest) by running 'make pkg-upgrade'")


def main():
    build_files = list(Path(".").rglob("build.act.json"))

    if not build_files:
        print("No build.act.json files found")
        return 0

    print(f"Checking dependency version consistency across {len(build_files)} build.act.json files...")
    # Extract dependencies from each file
    all_deps = {}
    for file_path in build_files:
        print(f"  {file_path}")
        deps = extract_dependencies(file_path)
        if deps:  # Only include files with external dependencies
            all_deps[file_path] = deps

    inconsistent = check_consistency(all_deps)
    print_report(inconsistent)
    return 1 if inconsistent else 0


if __name__ == "__main__":
    sys.exit(main())
