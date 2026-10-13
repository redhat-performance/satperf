#!/usr/bin/env python3
"""Patch live quadlet-managed containers via bind mounts.

This is the live-patching companion to ``build_patched_container_image.py``.
It accepts the same PR/diff inputs, but instead of building a new image it:

1. Extracts the relevant runtime directories from a base image.
2. Applies the requested diffs locally.
3. Writes quadlet drop-ins with ``Volume=`` bind mounts for the patched trees.
4. Reloads systemd and restarts the selected container services.

The script is intentionally strict:
- patch application must succeed
- gemspec dependency changes are rejected because they require an image rebuild
- target quadlet container units must be specified explicitly

Example:
    sudo ./patch_container_image.py \\
        --pr theforeman/foreman:10942 \\
        --pr Katello/katello:11701 \\
        --container-unit foreman \\
        --tag reg-hotfix

Example (apply_prs format):
    sudo ./patch_container_image.py --apply-prs '{
        targets: [
            {org: theforeman, repo: foreman,
             base_dir: /usr/share/foreman, prs: [10942, 10955]},
            {org: Katello, repo: katello,
             base_dir: "/usr/share/gems/gems/katello-*",
             prs: [11701]}
        ]
    }' --container-unit foreman --tag pr-bundle

Example (per-file mounts for independent per-PR layers):
    sudo ./patch_container_image.py \\
        --pr theforeman/foreman:10969 \\
        --container-unit foreman \\
        --tag pr-10969 \\
        --dropin-name 11-pr-10969.conf \\
        --per-file-mounts \\
        --no-restart
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import logging
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_patched_container_image import (  # noqa: E402
    DEFAULT_EXCLUDES,
    parse_apply_prs,
    parse_diff,
    parse_gemspec_changes,
    parse_pr,
    fetch_diff,
    fetch_pr_head,
    fetch_pr_changed_files,
    fetch_raw_file,
    copy_diff,
)

GEMSPEC_PATTERNS = ('*.gemspec', 'Gemfile', 'Gemfile.lock')

log = logging.getLogger(__name__)


def run(command, cwd=None, capture_output=False, check=True):
    """Run a subprocess and return the completed result."""
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        capture_output=capture_output,
    )
    if check and result.returncode != 0:
        if capture_output:
            if result.stdout:
                log.error(result.stdout.rstrip())
            if result.stderr:
                log.error(result.stderr.rstrip())
        log.error("Command failed: %s", " ".join(shlex.quote(part) for part in command))
        sys.exit(result.returncode or 1)
    return result


def run_shell(command, cwd=None):
    """Run a shell command through bash -lc."""
    return run(["bash", "-lc", command], cwd=cwd, capture_output=True)


def sanitize_name(value):
    """Turn an arbitrary string into a filesystem-safe name."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-") or "patch"


def default_base_dir_for_repo(repo):
    """Infer the in-container base directory from a repository name."""
    if repo == "foreman":
        return "/usr/share/foreman"
    return f"/usr/share/gems/gems/{repo}-*"


def normalize_container_unit(unit_name):
    """Normalize container unit names to their quadlet stem."""
    normalized = unit_name
    if normalized.endswith(".service"):
        normalized = normalized[:-8]
    if normalized.endswith(".container"):
        normalized = normalized[:-10]
    return normalized


def collect_patch_entries(args, work_dir):
    """Build a normalized list of patch entries from CLI arguments."""
    entries = []
    if args.apply_prs:
        data = parse_apply_prs(args.apply_prs)
        for target in data["targets"]:
            org = target["org"]
            repo = target["repo"]
            base_dir = target["base_dir"]
            excludes = target.get("exclude_patterns", DEFAULT_EXCLUDES)
            for pr_number in target["prs"]:
                diff_file = fetch_diff(org, repo, int(pr_number), work_dir)
                entries.append(
                    {
                        "org": org,
                        "repo": repo,
                        "ref": str(pr_number),
                        "diff_path": Path(work_dir) / diff_file,
                        "base_dir": base_dir,
                        "excludes": excludes,
                    }
                )
    else:
        excludes = args.exclude or DEFAULT_EXCLUDES
        for org, repo, pr_number in args.pr or []:
            diff_file = fetch_diff(org, repo, pr_number, work_dir)
            entries.append(
                {
                    "org": org,
                    "repo": repo,
                    "ref": str(pr_number),
                    "diff_path": Path(work_dir) / diff_file,
                    "base_dir": default_base_dir_for_repo(repo),
                    "excludes": excludes,
                }
            )
        for org, repo, diff_path in args.diff or []:
            diff_file = copy_diff(org, repo, diff_path, work_dir)
            entries.append(
                {
                    "org": org,
                    "repo": repo,
                    "ref": os.path.basename(diff_path),
                    "diff_path": Path(work_dir) / diff_file,
                    "base_dir": default_base_dir_for_repo(repo),
                    "excludes": excludes,
                }
            )
    return entries


def _is_excluded(filename, excludes):
    """Match a repo-relative path against filterdiff-style exclude patterns.

    The patterns (e.g. '*/test/*') are written assuming the 'a/'/'b/' prefix
    unified diffs put in front of every path, so a bare top-level path like
    'test/foo.rb' needs a leading '/' added before matching or '*/test/*'
    never matches anything at the repo root.
    """
    return any(fnmatch.fnmatch(f"/{filename}", pattern) for pattern in excludes)


def _collect_whole_file_pr(org, repo, pr_number, base_dir, excludes, work_dir):
    """Fetch every non-excluded changed file at a PR's branch tip.

    Returns an entry dict shaped like collect_patch_entries' output, but
    carrying fetched file contents ("pr_files") instead of a diff to apply -
    the caller writes them directly rather than invoking patch.
    """
    head_repo, head_ref = fetch_pr_head(org, repo, pr_number)
    log.info("Fetching %s/%s#%s files from %s@%s", org, repo, pr_number, head_repo, head_ref)
    changed = fetch_pr_changed_files(org, repo, pr_number)

    pr_files = []
    for change in changed:
        filename = change["filename"]
        if change["status"] == "removed":
            log.warning("Skipping removed file %s (bind mounts can't delete)", filename)
            continue
        if _is_excluded(filename, excludes):
            continue
        local_path = Path(work_dir) / f"{org}-{repo}-{pr_number}" / filename
        if not fetch_raw_file(head_repo, head_ref, filename, str(local_path)):
            log.error("Failed to fetch %s from %s@%s", filename, head_repo, head_ref)
            sys.exit(1)
        pr_files.append({"filename": filename, "local_path": local_path})

    return {
        "org": org,
        "repo": repo,
        "ref": str(pr_number),
        "pr_files": pr_files,
        "base_dir": base_dir,
        "excludes": excludes,
    }


def collect_whole_file_entries(args, work_dir):
    """Like collect_patch_entries, but fetches whole files instead of diffs."""
    entries = []
    if args.apply_prs:
        data = parse_apply_prs(args.apply_prs)
        for target in data["targets"]:
            excludes = target.get("exclude_patterns", DEFAULT_EXCLUDES)
            for pr_number in target["prs"]:
                entries.append(_collect_whole_file_pr(
                    target["org"], target["repo"], int(pr_number),
                    target["base_dir"], excludes, work_dir,
                ))
    else:
        excludes = args.exclude or DEFAULT_EXCLUDES
        for org, repo, pr_number in args.pr or []:
            entries.append(_collect_whole_file_pr(
                org, repo, pr_number, default_base_dir_for_repo(repo), excludes, work_dir,
            ))
    return entries


MIGRATION_PATTERN = "db/migrate/*.rb"


def write_whole_files(entry, work_tree):
    """Overlay fetched whole-file contents onto an extracted base tree.

    Paths under a dangling symlink (db/log/public point outside the app
    tree to runtime-data paths with no content in a bare extraction) can't
    be created this way. Returns the migration files among those (handled
    separately via apply_live_migrations); anything else is just skipped.
    """
    migrations = []
    for pr_file in entry["pr_files"]:
        dest = work_tree / pr_file["filename"]
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
        except (FileNotFoundError, FileExistsError):
            if fnmatch.fnmatch(pr_file["filename"], MIGRATION_PATTERN):
                migrations.append(pr_file)
            else:
                log.warning(
                    "Skipping %s: %s is a dangling symlink (runtime-data "
                    "path, not present in a bare extraction).",
                    pr_file["filename"], dest.parent,
                )
            continue
        shutil.copyfile(pr_file["local_path"], dest)
        log.info("  wrote %s", pr_file["filename"])
    return migrations


def apply_live_migrations(migration_files):
    """Copy migrations into the live foreman container and run them.

    db/migrate isn't reachable through the bind-mounted tree (it's a
    dangling symlink in a bare extraction), and podman cp only persists to
    a container's own writable layer anyway - so this runs independently of
    the Volume= drop-in, against whatever foreman container is live right
    now. The migration itself lands in Postgres, which is what needs to
    survive, not the copied .rb file.
    """
    for migration in migration_files:
        log.info("Applying live migration %s", migration["filename"])
        run(["podman", "cp", str(migration["local_path"]),
             "foreman:/usr/share/foreman/db/migrate/"])
        for attempt in range(10):
            result = run(["podman", "exec", "foreman", "foreman-rake", "db:migrate"],
                         capture_output=True, check=False)
            if result.returncode == 0:
                break
            log.warning("foreman-rake db:migrate failed (attempt %d/10), retrying...", attempt + 1)
            time.sleep(5)
        else:
            log.error("foreman-rake db:migrate failed for %s", migration["filename"])
            if result.stdout:
                log.error(result.stdout.rstrip())
            if result.stderr:
                log.error(result.stderr.rstrip())
            sys.exit(result.returncode or 1)


def reject_gemspec_changes(entries):
    """Fail if any diff/whole-file entry changes gem dependencies."""
    offenders = []
    for entry in entries:
        if "pr_files" in entry:
            touched = [f["filename"] for f in entry["pr_files"]
                       if any(fnmatch.fnmatch(f["filename"], p) for p in GEMSPEC_PATTERNS)]
            if touched:
                offenders.append({"entry": entry, "install": touched, "remove": []})
            continue
        to_install, to_remove, _ = parse_gemspec_changes(entry["diff_path"])
        if to_install or to_remove:
            offenders.append(
                {
                    "entry": entry,
                    "install": to_install,
                    "remove": to_remove,
                }
            )
    if offenders:
        for offender in offenders:
            entry = offender["entry"]
            log.error(
                "Diff %s/%s#%s changes gem dependencies (install=%s remove=%s)",
                entry["org"],
                entry["repo"],
                entry["ref"],
                offender["install"],
                offender["remove"],
            )
        log.error(
            "Live bind-mount patching does not install new dependencies. "
            "Use build_patched_container_image.py for those changes."
        )
        sys.exit(1)


def resolve_image_path(base_image, base_dir):
    """Resolve a possibly globbed path inside the image."""
    command = f"ls -d {base_dir} 2>/dev/null | head -1"
    result = run(
        ["podman", "run", "--rm", "--entrypoint", "sh", base_image, "-lc", command],
        capture_output=True,
    )
    resolved = result.stdout.strip()
    if not resolved:
        log.error("Could not resolve base_dir %s inside image %s", base_dir, base_image)
        sys.exit(1)
    return resolved


def extract_image_tree(container_id, resolved_path, destination_root):
    """Copy a directory tree from a container image into destination_root.

    Uses podman mount + cp -a rather than podman cp, which always chowns
    extracted files to the copying process (root) regardless of --archive -
    a file only readable by a non-root group in the image (e.g. a secret
    initializer readable by the app's own user) would otherwise become
    unreadable once this tree is bind-mounted back over the live container.
    """
    destination_root.mkdir(parents=True, exist_ok=True)
    mount_point = run(["podman", "mount", container_id], capture_output=True).stdout.strip()
    try:
        run(["cp", "-a", f"{mount_point}{resolved_path}", str(destination_root)])
    finally:
        run(["podman", "umount", container_id])
    copied_path = destination_root / Path(resolved_path).name
    if not copied_path.exists():
        log.error("Failed to extract %s from container %s", resolved_path, container_id)
        sys.exit(1)
    return copied_path


def apply_diff(diff_path, work_tree, excludes, allow_partial=False):
    """Apply a diff to a work tree.

    Returns True on clean success.  When allow_partial is True, a non-zero
    exit from patch is tolerated as long as at least one hunk applied (the
    caller detects actual changes via checksums).
    """
    exclude_args = " ".join(f"--exclude={shlex.quote(pattern)}" for pattern in excludes)
    command = (
        f"filterdiff {exclude_args} < {shlex.quote(str(diff_path))} "
        f"| patch -p1 --forward --batch"
    )
    result = run(["bash", "-lc", command], cwd=work_tree, capture_output=True, check=False)
    if result.returncode != 0:
        output = (result.stdout or "") + (result.stderr or "")
        if "Invalid file name" in output and ".rej" not in output:
            # A target path under a dangling symlink (e.g. db/migrate - see
            # write_whole_files) can't be created here either; patch itself
            # already skipped just that file and applied the rest.
            log.warning(
                "Patch for %s skipped an unwritable path (dangling symlink); "
                "other files still applied.",
                diff_path,
            )
            log.warning(output.rstrip())
            return True
        if allow_partial and "patching file" in output:
            log.warning(
                "Partial patch for %s (rc=%d); some hunks may have been skipped.",
                diff_path,
                result.returncode,
            )
            if result.stdout:
                log.warning(result.stdout.rstrip())
            return True
        log.error("Patch failed for %s", diff_path)
        if result.stdout:
            log.error(result.stdout.rstrip())
        if result.stderr:
            log.error(result.stderr.rstrip())
        sys.exit(result.returncode or 1)
    return True


def snapshot_checksums(tree_root):
    """Record mtime of every file under tree_root before patching."""
    checksums = {}
    for path in tree_root.rglob("*"):
        if path.is_file():
            checksums[path.relative_to(tree_root)] = path.stat().st_mtime_ns
    return checksums


def find_changed_files(tree_root, before_checksums):
    """Return relative paths of files that were added or modified since the snapshot."""
    changed = []
    for path in tree_root.rglob("*"):
        if path.is_file():
            rel = path.relative_to(tree_root)
            if rel not in before_checksums or path.stat().st_mtime_ns != before_checksums[rel]:
                changed.append(rel)
    return sorted(changed)


def ensure_quadlet_units_exist(units):
    """Validate that the requested quadlet container units exist locally."""
    quadlet_root = Path("/etc/containers/systemd")
    missing = []
    for unit in units:
        container_file = quadlet_root / f"{unit}.container"
        if not container_file.exists():
            missing.append(str(container_file))
    if missing:
        for path in missing:
            log.error("Missing quadlet container definition: %s", path)
        sys.exit(1)


def write_dropins(units, dropin_name, mount_specs):
    """Write quadlet drop-ins with bind mounts for each requested unit."""
    quadlet_root = Path("/etc/containers/systemd")
    dropin_paths = []
    lines = ["[Container]"]
    for spec in mount_specs:
        lines.append(f"Volume={spec['host_path']}:{spec['container_path']}:ro,z")
    content = "\n".join(lines) + "\n"

    for unit in units:
        dropin_dir = quadlet_root / f"{unit}.container.d"
        dropin_dir.mkdir(parents=True, exist_ok=True)
        dropin_path = dropin_dir / dropin_name
        dropin_path.write_text(content, encoding="utf-8")
        dropin_paths.append(dropin_path)
    return dropin_paths


def restart_units(units):
    """Reload systemd and restart the affected container services."""
    service_names = [f"{unit}.service" for unit in units]
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "restart", *service_names])
    status = run(["systemctl", "is-active", *service_names], capture_output=True)
    for line in status.stdout.splitlines():
        print(line)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--base",
        "--base-image",
        dest="base",
        default="quay.io/foreman/foreman:nightly",
        help="Base container image to extract runtime files from (default: %(default)s)",
    )
    parser.add_argument(
        "--apply-prs",
        metavar="JSON",
        help="apply_prs JSON/YAML string (same format as build_patched_container_image.py)",
    )
    parser.add_argument(
        "--pr",
        action="append",
        type=parse_pr,
        metavar="ORG/REPO:NUMBER",
        help="PR to apply (repeatable). Accepts org/repo:number or GitHub PR URL.",
    )
    parser.add_argument(
        "--diff",
        action="append",
        type=parse_diff,
        metavar="ORG/REPO:/PATH/TO.diff",
        help="Local diff to apply (repeatable).",
    )
    parser.add_argument(
        "--container-unit",
        action="append",
        required=True,
        metavar="UNIT",
        help=(
            "Quadlet container unit stem to patch (repeatable). "
            "Example: foreman or pulp-api"
        ),
    )
    parser.add_argument(
        "--tag",
        default="live-patched",
        help="Label used for the patch root directory (default: %(default)s)",
    )
    parser.add_argument(
        "--patch-root",
        default="/var/tmp/satperf-live-patches",
        help="Parent directory for extracted and patched trees (default: %(default)s)",
    )
    parser.add_argument(
        "--dropin-name",
        default="10-satperf-live-patch.conf",
        help="Drop-in filename to write under each .container.d directory",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        metavar="PATTERN",
        help=f"filterdiff exclude pattern (default: {DEFAULT_EXCLUDES})",
    )
    parser.add_argument(
        "--per-file-mounts",
        action="store_true",
        help=(
            "Mount individual changed files instead of whole directories. "
            "Enables independent per-PR drop-in layers that don't conflict."
        ),
    )
    parser.add_argument(
        "--whole-file",
        action="store_true",
        help=(
            "Fetch each PR's changed files whole, from the tip of its source "
            "branch, instead of downloading and applying a diff. Avoids "
            "patch-application mismatches against a non-matching base image, "
            "at the cost of needing GitHub API access (not just raw/diff "
            "URLs). Incompatible with --diff (no PR to look up files for)."
        ),
    )
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help="Write drop-ins but skip systemctl restart. Useful when batching multiple patches.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace an existing patch root for the same tag.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Prepare files and print actions, but do not write drop-ins or restart services.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    args = parser.parse_args()

    if not args.apply_prs and not args.pr and not args.diff:
        parser.error("one of --apply-prs, --pr, or --diff is required")
    if args.whole_file and args.diff:
        parser.error("--whole-file fetches files from a PR; --diff has no PR to look up")

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    units = [normalize_container_unit(unit) for unit in args.container_unit]
    patch_root = Path(args.patch_root) / sanitize_name(args.tag)
    if patch_root.exists():
        if args.force:
            shutil.rmtree(patch_root)
        else:
            log.error("Patch root already exists: %s (use --force to replace it)", patch_root)
            sys.exit(1)
    patch_root.mkdir(parents=True, exist_ok=True)

    if not args.dry_run and os.geteuid() != 0:
        log.error("This script must run as root unless --dry-run is used.")
        sys.exit(1)

    with tempfile.TemporaryDirectory(prefix="container-patch-diffs-") as diff_dir:
        entries = (
            collect_whole_file_entries(args, diff_dir)
            if args.whole_file
            else collect_patch_entries(args, diff_dir)
        )
        reject_gemspec_changes(entries)

        if not args.dry_run:
            ensure_quadlet_units_exist(units)

        container_id = run(["podman", "create", args.base], capture_output=True).stdout.strip()
        if not container_id:
            log.error("Failed to create temporary container from %s", args.base)
            sys.exit(1)

        try:
            mount_specs = []
            extracted = {}

            for entry in entries:
                base_dir = entry["base_dir"]
                if base_dir in extracted:
                    continue

                resolved_path = resolve_image_path(args.base, base_dir)
                target_name = sanitize_name(resolved_path.strip("/"))
                destination_root = patch_root / "trees" / target_name
                working_parent = destination_root.parent
                copied_path = extract_image_tree(container_id, resolved_path, working_parent)
                if copied_path != destination_root:
                    if destination_root.exists():
                        shutil.rmtree(destination_root)
                    copied_path.rename(destination_root)

                extracted[base_dir] = {
                    "resolved_path": resolved_path,
                    "host_path": destination_root,
                }

            pre_checksums = {}
            if args.per_file_mounts:
                for base_dir, info in extracted.items():
                    pre_checksums[base_dir] = snapshot_checksums(info["host_path"])

            pending_migrations = []
            for entry in entries:
                work_tree = extracted[entry["base_dir"]]["host_path"]
                log.info(
                    "Applying %s/%s#%s into %s",
                    entry["org"],
                    entry["repo"],
                    entry["ref"],
                    work_tree,
                )
                if "pr_files" in entry:
                    pending_migrations += write_whole_files(entry, work_tree)
                else:
                    apply_diff(entry["diff_path"], work_tree, entry["excludes"],
                               allow_partial=args.per_file_mounts)

            all_changed_files = {}
            if args.per_file_mounts:
                for base_dir, info in extracted.items():
                    changed = find_changed_files(info["host_path"], pre_checksums[base_dir])
                    all_changed_files[base_dir] = changed
                    resolved_path = info["resolved_path"]
                    host_tree = info["host_path"]
                    for rel_path in changed:
                        mount_specs.append(
                            {
                                "container_path": f"{resolved_path}/{rel_path}",
                                "host_path": str(host_tree / rel_path),
                            }
                        )
                    log.info(
                        "%d changed file(s) in %s",
                        len(changed),
                        resolved_path,
                    )
                if not mount_specs:
                    log.warning("No files were changed by the applied diffs.")
            else:
                for base_dir, info in extracted.items():
                    mount_specs.append(
                        {
                            "container_path": info["resolved_path"],
                            "host_path": str(info["host_path"]),
                        }
                    )

            manifest = {
                "tag": args.tag,
                "base_image": args.base,
                "units": units,
                "dropin_name": args.dropin_name,
                "per_file_mounts": args.per_file_mounts,
                "mounts": mount_specs,
                "entries": [
                    {
                        "org": entry["org"],
                        "repo": entry["repo"],
                        "ref": entry["ref"],
                        "base_dir": entry["base_dir"],
                        "resolved_path": extracted[entry["base_dir"]]["resolved_path"],
                        **(
                            {
                                "changed_files": [
                                    str(p) for p in all_changed_files.get(entry["base_dir"], [])
                                ],
                            }
                            if args.per_file_mounts
                            else {}
                        ),
                    }
                    for entry in entries
                ],
            }
            manifest_path = patch_root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            if args.dry_run:
                print(json.dumps(manifest, indent=2))
                print("\nPlanned drop-in content:\n")
                print("[Container]")
                for spec in mount_specs:
                    print(f"Volume={spec['host_path']}:{spec['container_path']}:ro,z")
                if pending_migrations:
                    print("\nPlanned live migrations:")
                    for migration in pending_migrations:
                        print(f"  {migration['filename']}")
                return

            apply_live_migrations(pending_migrations)

            dropin_paths = write_dropins(units, args.dropin_name, mount_specs)
            if not args.no_restart:
                restart_units(units)

            print(f"\nLive patch applied from: {patch_root}")
            print(f"Manifest: {manifest_path}")
            print("\nDrop-ins:")
            for path in dropin_paths:
                print(f"  {path}")

            print("\nRollback:")
            for path in dropin_paths:
                print(f"  rm -f {shlex.quote(str(path))}")
            print("  systemctl daemon-reload")
            print(
                "  systemctl restart "
                + " ".join(shlex.quote(f"{unit}.service") for unit in units)
            )
            print(f"  rm -rf {shlex.quote(str(patch_root))}")
        finally:
            run(["podman", "rm", "-f", container_id], check=False, capture_output=True)


if __name__ == "__main__":
    main()
