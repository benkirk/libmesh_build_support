#!/usr/bin/env python3
"""Prune old container versions from GHCR.

Adapted from benkirk/sam-queries' prune_ghcr_packages.py.  Two things about
this repository's tags make the policy different from that one's.

TAGS ARE CONTENT HASHES, not commit SHAs.  A tag looks like

    linux-64-openblas-mpich-3d0775e

so there is no 'latest' to anchor on and no ordering implied by the name.  Two
commits that do not touch conda/ or the build machinery produce the SAME tag,
which is the point -- but it also means "keep the 10 newest" has to be applied
PER CONFIGURATION LINE.  Keeping the 10 newest overall would let a busy
linux-64 line evict every linux-aarch64 tag, and the aarch64 ones are the
harder to rebuild.

UNTAGGED VERSIONS ARE NOT GARBAGE HERE, and this is the trap the original
walks into.  buildx publishes each tag as an index: a manifest list pointing at
the image manifest and an attestation manifest.  On GHCR those children appear
as separate, UNTAGGED versions -- verified in a local build, which emitted

    exporting manifest sha256:b572cea...
    exporting attestation manifest sha256:6c19cb2...
    exporting manifest list sha256:66946e2...

Deleting untagged versions unconditionally therefore deletes the children of
tags you meant to keep, and leaves a tag that resolves to nothing.  So untagged
pruning is off by default, and when enabled it first walks the retained tags'
manifests and protects everything they reference.

WHAT IS NOT POSSIBLE: deleting versions nobody has pulled.  The GitHub Packages
API returns id, name, url, html_url, license, description, created_at,
updated_at, deleted_at and metadata -- and no download count, pull count or
last-accessed timestamp, for containers or any other package type.  updated_at
tracks metadata changes, not reads.  There is no audit-log route for package
pulls on a personal account either.  So "has this been pulled?" is not
unreliable here, it is simply not exposed, and age within a configuration line
is the best available proxy.

  Authentication is gh's: GH_TOKEN needs packages:write to delete.  Reading a
  public package's manifests needs no credentials at all.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

# A tag this script understands: <platform>-<blas>-<mpi>-<7 hex>.  The prefix
# is the configuration line; the suffix is the content hash.
HASH_TAG = re.compile(r"^(?P<config>.+)-(?P<sha>[0-9a-f]{7})$")

MANIFEST_ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def gh_api(args: list[str]) -> str:
    res = subprocess.run(["gh", "api", *args],
                         capture_output=True, text=True, check=True)
    return res.stdout.strip()


def fetch_versions(pkg_encoded: str, owner: str) -> list[dict]:
    try:
        out = gh_api(["--paginate",
                      f"users/{owner}/packages/container/{pkg_encoded}/versions"])
    except subprocess.CalledProcessError as exc:
        print(f"error: fetching {pkg_encoded}: {exc.stderr}", file=sys.stderr)
        return []
    return json.loads(out) if out else []


def delete_version(pkg_encoded: str, owner: str, vid: int, dry_run: bool) -> bool:
    if dry_run:
        return True
    try:
        gh_api(["-X", "DELETE",
                f"users/{owner}/packages/container/{pkg_encoded}/versions/{vid}"])
        return True
    except subprocess.CalledProcessError as exc:
        print(f"::warning::failed to delete version {vid}: {exc.stderr}",
              file=sys.stderr)
        return False


def referenced_digests(repo_path: str, digests: list[str]) -> set[str]:
    """Digests referenced BY the given manifests, for public packages.

    Anonymous pull token, so this needs no credentials for a public package.
    Any failure returns nothing extra and the caller treats untagged versions
    as unsafe to delete -- failing towards keeping things.
    """
    found: set[str] = set()
    try:
        url = (f"https://ghcr.io/token?scope=repository:{repo_path}:pull"
               f"&service=ghcr.io")
        with urllib.request.urlopen(url, timeout=30) as fh:
            token = json.load(fh).get("token")
    except Exception as exc:                      # noqa: BLE001 - report and bail
        print(f"::warning::could not get a registry token for {repo_path}: {exc}",
              file=sys.stderr)
        return found

    for digest in digests:
        req = urllib.request.Request(
            f"https://ghcr.io/v2/{repo_path}/manifests/{digest}",
            headers={"Accept": MANIFEST_ACCEPT,
                     "Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as fh:
                doc = json.load(fh)
        except Exception as exc:                  # noqa: BLE001
            print(f"::warning::could not read manifest {digest[:19]}: {exc}",
                  file=sys.stderr)
            continue
        for child in doc.get("manifests", []):
            if child.get("digest"):
                found.add(child["digest"])
    return found


def plan(versions: list[dict], keep: int, protect: re.Pattern | None):
    """Split versions into (keep, delete, untagged) with a reason for each."""
    keeps, deletes, untagged = [], [], []
    seen_per_config: dict[str, int] = {}

    # created_at descending, so "newest N" is the first N of each line.
    for v in sorted(versions, key=lambda v: v.get("created_at", ""), reverse=True):
        tags = v.get("metadata", {}).get("container", {}).get("tags", [])
        if not tags:
            untagged.append(v)
            continue
        if protect and any(protect.match(t) for t in tags):
            keeps.append((v, f"protected {tags}"))
            continue

        m = next((HASH_TAG.match(t) for t in tags if HASH_TAG.match(t)), None)
        if not m:
            # Defensive, as in the original: an unrecognised convention is
            # somebody else's intent, not garbage.
            keeps.append((v, f"unrecognised tags {tags}"))
            continue

        config = m.group("config")
        n = seen_per_config.get(config, 0)
        if n < keep:
            seen_per_config[config] = n + 1
            keeps.append((v, f"{config} #{n + 1} of {keep}"))
        else:
            deletes.append((v, f"{config} beyond {keep}"))
    return keeps, deletes, untagged


def prune_package(pkg: str, owner: str, keep: int, protect, dry_run: bool,
                  prune_untagged: bool) -> int:
    pkg_encoded = urllib.parse.quote(pkg, safe="")
    versions = fetch_versions(pkg_encoded, owner)
    print(f"\n=== {owner}/{pkg}: {len(versions)} versions")
    if not versions:
        return 0

    keeps, deletes, untagged = plan(versions, keep, protect)
    for v, why in keeps:
        print(f"  keep    {v['id']}  {why}")
    for v, why in deletes:
        print(f"  DELETE  {v['id']}  {why}")

    if untagged:
        if not prune_untagged:
            print(f"  keep    {len(untagged)} untagged "
                  f"(--prune-untagged not given; they may be manifest-list "
                  f"children of tags above)")
        else:
            protected = referenced_digests(
                f"{owner}/{pkg}", [v["name"] for v, _ in keeps])
            for v in untagged:
                if v["name"] in protected:
                    print(f"  keep    {v['id']}  untagged, referenced by a kept tag")
                else:
                    deletes.append((v, "untagged, unreferenced"))
                    print(f"  DELETE  {v['id']}  untagged, unreferenced")

    done = 0
    for v, _ in deletes:
        if delete_version(pkg_encoded, owner, v["id"], dry_run):
            done += 1
    return done


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner", default=os.environ.get("GITHUB_REPOSITORY_OWNER"))
    ap.add_argument("--repo",
                    default=os.environ.get("GITHUB_REPOSITORY", "").split("/")[-1] or None)
    ap.add_argument("--package", action="append", dest="packages", metavar="NAME",
                    help="package name relative to --repo; repeatable "
                         "(default: builder, devel)")
    ap.add_argument("--keep", type=int, default=10, metavar="N",
                    help="versions to retain PER CONFIGURATION LINE (default 10)")
    ap.add_argument("--protect", default=None, metavar="REGEX",
                    help="tags matching this are never deleted")
    ap.add_argument("--prune-untagged", action="store_true",
                    help="also delete untagged versions not referenced by any "
                         "retained tag (see this script's docstring first)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if not a.owner or not a.repo:
        print("--owner/--repo not set and the Actions context env is empty",
              file=sys.stderr)
        return 2

    protect = re.compile(a.protect) if a.protect else None
    if a.dry_run:
        print("[dry run] nothing will be deleted")

    total = 0
    for name in (a.packages or ["builder", "devel"]):
        total += prune_package(f"{a.repo}/{name}", a.owner, a.keep, protect,
                               a.dry_run, a.prune_untagged)

    verb = "would be deleted" if a.dry_run else "deleted"
    print(f"\n{total} version(s) {verb}")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(f"## Prune GHCR\n\n{total} version(s) {verb}, "
                     f"keeping {a.keep} per configuration line.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
