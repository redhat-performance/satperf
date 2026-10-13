#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_payload(source: Path, schema_uri: str | None) -> Path:
    payload = load_json(source)
    if schema_uri:
        payload["$schema"] = schema_uri

    tmp = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".json", prefix="horreum-status-data-", delete=False
    )
    with tmp:
        json.dump(payload, tmp, sort_keys=True)
        tmp.write("\n")
    return Path(tmp.name)


def run_command(command: list[str]) -> None:
    try:
        subprocess.run(command, check=True)
    except FileNotFoundError as exc:
        raise SystemExit(f"Failed to execute '{command[0]}': {exc}") from exc
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode) from exc


def upload(args: argparse.Namespace) -> int:
    input_file = Path(args.input_file)
    payload_file = write_payload(input_file, args.schema_uri)
    try:
        command = [
            args.shovel_command,
            "horreum",
            "--base-url",
            args.base_url,
            "--api-token",
            args.api_token,
            "upload",
            "--test-name",
            args.test_name,
            "--input-file",
            str(payload_file),
            "--matcher-field",
            args.matcher_field,
            "--matcher-label",
            args.matcher_label,
            "--owner",
            args.owner,
            "--access",
            args.access,
            "--start",
            "@started",
            "--end",
            "@ended",
            "--trashed",
            "--trashed-workaround-count",
            str(args.trashed_workaround_count),
        ]
        run_command(command)
    finally:
        payload_file.unlink(missing_ok=True)
    return 0


def compare(args: argparse.Namespace) -> int:
    comparisons = []

    for input_name in args.input_file:
        input_file = Path(input_name)
        expected = load_json(input_file).get("result")
        payload_file = write_payload(input_file, args.schema_uri)
        try:
            command = [
                args.shovel_command,
                "horreum",
                "--base-url",
                args.base_url,
                "--api-token",
                args.api_token,
                "result",
                "--test-name",
                args.test_name,
                "--output-file",
                str(payload_file),
                "--start",
                "@started",
                "--end",
                "@ended",
            ]
            run_command(command)
            horreum_result = load_json(payload_file).get("result")
        finally:
            payload_file.unlink(missing_ok=True)

        comparisons.append(
            {
                "file": str(input_file),
                "expected_result": expected,
                "horreum_result": horreum_result,
                "matches": expected == horreum_result,
            }
        )

    if args.report_file:
        report_path = Path(args.report_file)
        with report_path.open("w", encoding="utf-8") as handle:
            json.dump(comparisons, handle, indent=2, sort_keys=True)
            handle.write("\n")

    matched = sum(1 for item in comparisons if item["matches"])
    mismatched = len(comparisons) - matched
    print(f"Compared {len(comparisons)} files: {matched} matched, {mismatched} mismatched.")
    for item in comparisons:
        print(
            f"{item['file']}: investigator={item['expected_result']} "
            f"horreum={item['horreum_result']} match={item['matches']}"
        )

    if mismatched and args.fail_on_mismatch:
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Upload satperf status-data JSON to Horreum or compare Horreum results."
    )
    parser.add_argument(
        "--shovel-command",
        default="shovel.py",
        help="Command used to invoke the OPL Horreum helper.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    upload_parser = subparsers.add_parser("upload", help="Upload a single status-data file to Horreum.")
    upload_parser.set_defaults(func=upload)
    upload_parser.add_argument("--input-file", required=True, help="Path to a status-data JSON file.")
    upload_parser.add_argument("--base-url", required=True, help="Horreum base URL.")
    upload_parser.add_argument("--api-token", required=True, help="Horreum API token.")
    upload_parser.add_argument("--test-name", required=True, help="Pre-created Horreum test name.")
    upload_parser.add_argument("--schema-uri", required=True, help="Schema URI to stamp into the payload.")
    upload_parser.add_argument(
        "--matcher-field",
        default="parameters.horreum_upload_id",
        help="Unique field in the input document used to avoid duplicate uploads.",
    )
    upload_parser.add_argument(
        "--matcher-label",
        default="horreum_upload_id",
        help="Filtering label configured in Horreum for the matcher field.",
    )
    upload_parser.add_argument("--owner", required=True, help="Horreum team owner for uploaded runs.")
    upload_parser.add_argument("--access", default="PUBLIC", help="Horreum access level for uploaded runs.")
    upload_parser.add_argument(
        "--trashed-workaround-count",
        type=int,
        default=96,
        help="How many recent trashed runs to inspect when de-duplicating.",
    )

    compare_parser = subparsers.add_parser(
        "compare",
        help="Compare investigator results in status-data files with Horreum change detection.",
    )
    compare_parser.set_defaults(func=compare)
    compare_parser.add_argument(
        "--input-file",
        required=True,
        nargs="+",
        help="One or more status-data JSON files that already contain investigator results.",
    )
    compare_parser.add_argument("--base-url", required=True, help="Horreum base URL.")
    compare_parser.add_argument("--api-token", required=True, help="Horreum API token.")
    compare_parser.add_argument("--test-name", required=True, help="Existing Horreum test name.")
    compare_parser.add_argument(
        "--schema-uri",
        help="Optional schema URI to stamp into the temporary payload copy before evaluation.",
    )
    compare_parser.add_argument(
        "--report-file",
        help="Optional JSON report path for persisting the comparison summary.",
    )
    compare_parser.add_argument(
        "--fail-on-mismatch",
        action="store_true",
        help="Exit non-zero when investigator and Horreum disagree on any file.",
    )

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
