#!/usr/bin/env python3
"""Build a patched Foreman container image from a list of GitHub PRs.

Generates a Containerfile that layers PR diffs onto an RPM-based Foreman
image (e.g. quay.io/foreman/foreman:nightly), builds it with podman, and
prints the resulting tag for use with foremanctl.

Usage (apply_prs format — same as the Ansible role):
    ./build_patched_foreman.py --apply-prs '{
        targets: [
            {org: theforeman, repo: foreman,
             base_dir: /usr/share/foreman, prs: [10942, 10955]},
            {org: Katello, repo: katello,
             base_dir: "/usr/share/gems/gems/katello-*",
             prs: [11701]}
        ]
    }'

Usage (simple format):
    ./build_patched_foreman.py \\
        --pr theforeman/foreman:10942 \\
        --pr Katello/katello:11701 \\
        --tag localhost/foreman:pr-test

Integration with foremanctl:
    After building, override the foreman image in images.yml:
        foreman_container_image: "localhost/foreman"
        foreman_container_tag: "pr-test"
    Then run: foremanctl deploy
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile

log = logging.getLogger(__name__)

DEFAULT_EXCLUDES = ['*/test/*', '*/spec/*']
DEFAULT_FORGE = 'https://github.com'


def parse_pr(spec):
    """Parse 'org/repo:number' into (org, repo, number)."""
    try:
        repo_part, number = spec.rsplit(':', 1)
        org, repo = repo_part.split('/', 1)
        return org, repo, int(number)
    except (ValueError, AttributeError):
        raise argparse.ArgumentTypeError(
            f"Invalid PR format: '{spec}'. Expected org/repo:number "
            f"(e.g. theforeman/foreman:10942)"
        )


def parse_apply_prs(spec_string):
    """Parse apply_prs JSON/YAML string into a list of target dicts."""
    try:
        import yaml
        data = yaml.safe_load(spec_string)
    except ImportError:
        data = json.loads(spec_string)

    if not isinstance(data, dict) or 'targets' not in data:
        raise argparse.ArgumentTypeError(
            "apply_prs spec must have a 'targets' key"
        )
    for t in data['targets']:
        for key in ('org', 'repo', 'base_dir', 'prs'):
            if key not in t:
                raise argparse.ArgumentTypeError(
                    f"Target missing required key '{key}': {t}"
                )
    return data


def fetch_diff(org, repo, pr_number, dest_dir, forge=DEFAULT_FORGE):
    """Download a PR diff from GitHub/GitLab. Returns the local filename."""
    url = f'{forge}/{org}/{repo}/pull/{pr_number}.diff'
    filename = f'{org}-{repo}-{pr_number}.diff'
    dest = os.path.join(dest_dir, filename)
    log.info('Fetching %s/%s#%d → %s', org, repo, pr_number, filename)
    result = subprocess.run(
        ['curl', '-L', '-sf', '-o', dest, url],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        log.error('Failed to fetch %s (curl exit %d)', url, result.returncode)
        sys.exit(1)
    size = os.path.getsize(dest)
    if size == 0:
        log.error('Empty diff for %s/%s#%d — PR may not exist', org, repo, pr_number)
        sys.exit(1)
    log.info('  %d bytes', size)
    return filename


def patch_command(diff_file, base_dir, excludes):
    """Shell command to filterdiff + patch a diff file."""
    exclude_args = ' '.join(f"--exclude='{p}'" for p in excludes)
    return (
        f'cd {base_dir} && \\\n'
        f'    filterdiff {exclude_args} < /tmp/{diff_file} '
        f'| patch -p1 --forward --batch'
    )


def resolve_base_dir(base_dir):
    """Wrap glob-containing base_dir in shell expansion for Containerfile."""
    if '*' in base_dir or '?' in base_dir:
        return f'$(ls -d {base_dir} | head -1)'
    return base_dir


def generate_containerfile(pr_groups, base_image, gems, rebuild_assets):
    """Generate a Containerfile that applies PR diffs to the base image.

    pr_groups is a list of (org, repo, pr_number, diff_file, base_dir, excludes).
    """
    lines = [
        f'FROM {base_image}',
        'USER root',
        '',
        'RUN dnf install -y --nodocs patchutils && dnf clean all',
    ]

    if gems:
        gem_list = ' '.join(gems)
        lines.append('')
        lines.append('# Install prerequisite gems')
        lines.append(f'RUN gem install --no-document {gem_list}')

    for org, repo, pr_number, diff_file, base_dir, excludes in pr_groups:
        lines.append('')
        lines.append(f'# {org}/{repo}#{pr_number}')
        lines.append(f'COPY {diff_file} /tmp/')

        resolved = resolve_base_dir(base_dir)
        if resolved != base_dir:
            cmd = (
                f'PATCHDIR={resolved} && \\\n'
                f'    {patch_command(diff_file, "$PATCHDIR", excludes)}'
            )
        else:
            cmd = patch_command(diff_file, base_dir, excludes)

        lines.append(
            f'RUN {cmd} || \\\n'
            f'    echo "WARN: Patch {org}/{repo}#{pr_number} partially applied"'
        )

    if rebuild_assets:
        lines.append('')
        lines.append('RUN cd /usr/share/foreman && \\')
        lines.append('    RAILS_ENV=production DATABASE_URL=nulldb://nohost \\')
        lines.append('    bundle exec rake assets:precompile')

    lines.append('')
    lines.append('RUN dnf remove -y patchutils && dnf clean all && rm -f /tmp/*.diff')
    lines.append('USER foreman')
    lines.append('')

    return '\n'.join(lines)


def build_image(build_dir, tag):
    """Run podman build and return success status."""
    cmd = ['podman', 'build', '-t', tag, '-f', 'Containerfile', '.']
    log.info('Building: %s', ' '.join(cmd))
    result = subprocess.run(cmd, cwd=build_dir)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        '--base', default='quay.io/foreman/foreman:nightly',
        help='Base container image (default: %(default)s)',
    )

    pr_group = parser.add_mutually_exclusive_group(required=True)
    pr_group.add_argument(
        '--apply-prs', metavar='JSON',
        help='apply_prs JSON/YAML string (same format as the Ansible role)',
    )
    pr_group.add_argument(
        '--pr', action='append', type=parse_pr,
        metavar='ORG/REPO:NUMBER',
        help='PR to apply (repeatable). E.g. theforeman/foreman:10942',
    )

    parser.add_argument(
        '--tag', default='localhost/foreman:patched',
        help='Output image tag (default: %(default)s)',
    )
    parser.add_argument(
        '--exclude', action='append', metavar='PATTERN',
        help=f'filterdiff exclude pattern (default: {DEFAULT_EXCLUDES})',
    )
    parser.add_argument(
        '--gem', action='append', metavar='NAME',
        help='Ruby gem to install before patching (repeatable)',
    )
    parser.add_argument(
        '--rebuild-assets', action='store_true',
        help='Run rake assets:precompile after patching (for JS/webpack PRs)',
    )
    parser.add_argument(
        '--keep-builddir', action='store_true',
        help='Keep temporary build directory for debugging',
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Generate Containerfile and print it, but do not build',
    )
    parser.add_argument(
        '-v', '--verbose', action='store_true',
        help='Enable debug logging',
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(levelname)s: %(message)s',
        stream=sys.stderr,
    )

    build_dir = tempfile.mkdtemp(prefix='foreman-patch-')
    log.info('Build directory: %s', build_dir)

    try:
        pr_entries = []

        if args.apply_prs:
            data = parse_apply_prs(args.apply_prs)
            for target in data['targets']:
                org = target['org']
                repo = target['repo']
                base_dir = target['base_dir']
                forge = target.get('forge', DEFAULT_FORGE)
                excludes = target.get('exclude_patterns', DEFAULT_EXCLUDES)
                for pr_number in target['prs']:
                    diff_file = fetch_diff(
                        org, repo, int(pr_number), build_dir, forge,
                    )
                    pr_entries.append(
                        (org, repo, int(pr_number), diff_file, base_dir, excludes)
                    )
        else:
            excludes = args.exclude or DEFAULT_EXCLUDES
            for org, repo, pr_number in args.pr:
                diff_file = fetch_diff(org, repo, pr_number, build_dir)
                base_dir = '/usr/share/foreman' if repo == 'foreman' else \
                    f'/usr/share/gems/gems/{repo}-*'
                pr_entries.append(
                    (org, repo, pr_number, diff_file, base_dir, excludes)
                )

        containerfile = generate_containerfile(
            pr_entries, args.base, args.gem or [], args.rebuild_assets,
        )

        cf_path = os.path.join(build_dir, 'Containerfile')
        with open(cf_path, 'w') as f:
            f.write(containerfile)

        if args.dry_run:
            print(containerfile)
            log.info('Dry run — Containerfile written to %s', cf_path)
            return

        if not build_image(build_dir, args.tag):
            log.error('Build failed')
            sys.exit(1)

        image, tag_part = args.tag.rsplit(':', 1)
        print(f'\nImage built: {args.tag}')
        print('\nforemanctl images.yml override:')
        print(f'  foreman_container_image: "{image}"')
        print(f'  foreman_container_tag: "{tag_part}"')

    finally:
        if args.keep_builddir:
            log.info('Build directory kept: %s', build_dir)
        else:
            shutil.rmtree(build_dir, ignore_errors=True)


if __name__ == '__main__':
    main()
