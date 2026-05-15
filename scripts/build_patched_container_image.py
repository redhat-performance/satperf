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

Gem dependencies are auto-detected from gemspec changes in PR diffs.

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


def parse_gem_dependency(line):
    """Extract gem name and version from a gemspec add_dependency line.

    Examples:
        '  gem.add_dependency "faraday", ">= 2.0.0", "< 3.0.0"' -> ('faraday', '>= 2.0.0')
        '  gem.add_dependency "faraday-multipart", "~> 1.0"'     -> ('faraday-multipart', '~> 1.0')
        '  gem.add_dependency "rest-client"'                      -> ('rest-client', None)
    """
    import re
    m = re.search(r'add_dependency\s+["\']([^"\']+)["\'](?:\s*,\s*["\']([^"\']+)["\'])?', line)
    if not m:
        return None, None
    return m.group(1), m.group(2)


def parse_gemspec_changes(diff_path):
    """Scan a PR diff for gemspec dependency changes.

    Returns (gems_to_install, gems_to_remove, old_versions) where:
      gems_to_install: list of gem specs ('name:version') for gem_install_cmd()
      gems_to_remove: sorted list of gem names to remove
      old_versions: dict of {gem_name: old_version_constraint} for spec patching
    """
    to_install = []
    to_remove = set()
    old_versions = {}
    in_gemspec = False

    with open(diff_path) as f:
        for line in f:
            if line.startswith('diff --git') and '.gemspec' in line:
                in_gemspec = True
                continue
            if line.startswith('diff --git'):
                in_gemspec = False
                continue
            if not in_gemspec:
                continue
            if not (line.startswith('+') or line.startswith('-')):
                continue
            if line.startswith('+++') or line.startswith('---'):
                continue
            if 'add_dependency' not in line:
                continue

            name, version = parse_gem_dependency(line[1:])
            if not name:
                continue

            if line.startswith('-'):
                to_remove.add(name)
                if version:
                    old_versions[name] = version
            elif line.startswith('+'):
                spec = f'{name}:{version}' if version else name
                to_install.append(spec)

    install_names = {s.split(':')[0] for s in to_install}
    pure_removes = to_remove - install_names

    return to_install, sorted(pure_removes), old_versions


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


def gem_install_cmd(gem_spec):
    """Convert a gem spec like 'faraday~>2.0' or 'faraday:~>2.0' into gem install args."""
    for sep in [':', '~>']:
        if sep in gem_spec and sep != ':':
            name, version = gem_spec.split('~>', 1)
            name = name.rstrip(':').strip()
            return f"gem install --no-document {name} --version '~> {version.strip()}'"
        elif ':' in gem_spec:
            parts = gem_spec.split(':', 1)
            if len(parts) == 2 and parts[1].strip():
                return f"gem install --no-document {parts[0]} --version '{parts[1].strip()}'"
    return f'gem install --no-document {gem_spec}'


def generate_containerfile(pr_groups, base_image, gems, gems_remove, spec_patches, spec_removes, rebuild_assets):
    """Generate a Containerfile that applies PR diffs to the base image.

    pr_groups is a list of (org, repo, pr_number, diff_file, base_dir, excludes).
    spec_patches is a list of (base_dir, gem_name, old_version, new_version) for version updates.
    spec_removes is a list of (base_dir, gem_name) for dependency removals.
    """
    lines = [
        f'FROM {base_image}',
        'USER root',
        '',
        'RUN dnf install -y --nodocs patchutils && dnf clean all',
    ]

    if gems_remove:
        lines.append('')
        lines.append('# Remove conflicting gems (rm for RPM-owned, uninstall for user-installed)')
        for gem_name in gems_remove:
            lines.append(
                f'RUN rm -rf /usr/share/gems/gems/{gem_name}-* '
                f'/usr/share/gems/specifications/{gem_name}-* || true'
            )

    if gems:
        lines.append('')
        lines.append('# Install gems')
        # Build tools needed for native extensions
        lines.append('RUN dnf install -y --nodocs gcc make ruby-devel redhat-rpm-config 2>/dev/null || true')
        for gem_spec in gems:
            lines.append(f'RUN {gem_install_cmd(gem_spec)}')
        lines.append('RUN dnf remove -y gcc make ruby-devel redhat-rpm-config 2>/dev/null && dnf clean all || true')

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

    if spec_patches or spec_removes:
        lines.append('')
        lines.append('# Update compiled gemspec specifications for bundler_ext')

        for base_dir, gem_name, old_version, new_version in spec_patches:
            spec_glob = base_dir.replace('/gems/gems/', '/gems/specifications/') + '.gemspec'
            spec_var = f'SPECFILE=$(ls {spec_glob} 2>/dev/null | head -1)'
            if old_version and new_version:
                lines.append(
                    f'RUN {spec_var} && \\\n'
                    f'    sed -i \'s|"{gem_name}", "{old_version}"|"{gem_name}", "{new_version}"|\' "$SPECFILE"'
                )
            elif new_version:
                lines.append(
                    f'RUN {spec_var} && \\\n'
                    f'    grep -q \'{gem_name}\' "$SPECFILE" || \\\n'
                    f'    sed -i \'/"faraday"/a\\  s.add_runtime_dependency(%q<{gem_name}>.freeze, ["{new_version}"])\' "$SPECFILE"'
                )

        for base_dir, gem_name in spec_removes:
            spec_glob = base_dir.replace('/gems/gems/', '/gems/specifications/') + '.gemspec'
            lines.append(
                f'RUN SPECFILE=$(ls {spec_glob} 2>/dev/null | head -1) && \\\n'
                f'    sed -i \'/{gem_name}/d\' "$SPECFILE" || true'
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

        auto_gems = []
        auto_removes = set()
        spec_patches = []  # (base_dir, gem_name, old_version, new_version)
        spec_removes = []  # (base_dir, gem_name)
        for _, _, pr_number, diff_file, base_dir, _ in pr_entries:
            diff_path = os.path.join(build_dir, diff_file)
            gems_install, gems_remove, old_versions = parse_gemspec_changes(diff_path)
            if gems_install or gems_remove:
                log.info('Gemspec changes detected in %s: install=%s remove=%s',
                         diff_file, gems_install, gems_remove)
            auto_gems.extend(gems_install)
            auto_removes.update(gems_remove)
            for gem_spec in gems_install:
                gem_name = gem_spec.split(':')[0]
                new_version = gem_spec.split(':', 1)[1] if ':' in gem_spec else None
                old_version = old_versions.get(gem_name)
                if old_version or new_version:
                    spec_patches.append((base_dir, gem_name, old_version, new_version))
            for gem_name in gems_remove:
                spec_removes.append((base_dir, gem_name))

        all_gems = auto_gems
        all_removes = sorted(auto_removes)

        containerfile = generate_containerfile(
            pr_entries, args.base, all_gems, all_removes, spec_patches, spec_removes, args.rebuild_assets,
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
