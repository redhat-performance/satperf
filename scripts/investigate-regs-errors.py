#!/usr/bin/env python

import collections
import csv
import logging
import os
import re
import sys

import ansible_parser.play


# Description of the issue and regexp on how to find it in the error message
issues = [
    {
        "name": 'PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "katello_available_module_streams_name_stream_context"',
        "regexp": r"PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint \\\"katello_available_module_streams_name_stream_context\\\"",
    },
    {
        "name": "could not obtain a connection from the pool within 5.000 seconds",
        "regexp": r"could not obtain a connection from the pool within 5.000 seconds",
    },
    {
        "name": "Network error, unable to connect to server.",
        "regexp": r"Network error, unable to connect to server. Please see /var/log/rhsm/rhsm.log for more information.",
    },
    {
        "name": "curl: (7) Failed to connect to <host> port 443: No route to host",
        "regexp": r"curl: \(7\) Failed to connect to [^ ]+ port 443: No route to host",
    },
    {
        "name": "No such file or directory @ rb_sysopen",
        ###         No such file or directory @ rb_sysopen - /usr/share/foreman/tmp/cache/1CC/031/.permissions_check.226080.30012.98543 (HTTP error code 500: Internal Server Error)
        "regexp": r"No such file or directory @ rb_sysopen - /usr/share/foreman/tmp/cache/[0-9a-zA-Z]+/[0-9a-zA-Z]+/.permissions_check.[0-9.]+ \(HTTP error code 500: Internal Server Error\)",
    },
    {
        "name": "Remote server error. Please check the connection details, or see /var/log/rhsm/rhsm.log for more information.",
        "regexp": r"Remote server error. Please check the connection details, or see /var/log/rhsm/rhsm.log for more information.",
    },
    {
        "name": "Internal Server Error: the server was unable to finish the request.",
        "regexp": r"Internal Server Error: the server was unable to finish the request. This may be caused by unavailability of some required service, incorrect API call or a server-side bug. There may be more information in the server's logs.",
    },
    {
        "name": "Unable to find available subscriptions for all your installed products.",
        "regexp": r"Unable to find available subscriptions for all your installed products.",
    },
    {
        "name": "Service unavailable or restarting, try later",
        "regexp": r"Service unavailable or restarting, try later",
    },
]


logging.basicConfig(level=logging.DEBUG)


def merge_results(*args):
    """
    Given multiple result dicts, return summary of all of them
    """
    results = collections.defaultdict(lambda: 0)
    for r in args:
        for k, v in r.items():
            results[k] += v
    return results


def stats_for_file(filename, target_task_name="Register"):
    """
    Parse a given playbook output and return count of issues found in
    given task name.
    """
    results = collections.defaultdict(lambda: 0)
    playbook_output = open(filename, "r").read()
    logging.debug(f"Processing playbook filename = {filename}")
    playbook = ansible_parser.play.Play(play_output=playbook_output)
    failures = playbook.failures()
    for play_name, play_content in playbook.plays().items():
        logging.debug(f"Processing play play_name = {play_name}")
        for task_name, task_content in play_content.items():
            if task_name != target_task_name:
                continue
            logging.debug(f"Processing task task_name = {task_name}")
            for result in task_content.results:
                logging.debug(
                    f"Processing result host = {result['host']}; status = {result['status']}; len(failure_message) = {len(result['failure_message'])}"
                )
                if len(result["failure_message"]) == 0:
                    results["OK"] += 1
                else:
                    matched = False
                    for issue in issues:
                        match = re.search(issue["regexp"], result["failure_message"])
                        if match:
                            logging.debug(f"Found match on rule {issue['name']}")
                            if matched:
                                raise Exception(
                                    f"Rule '{issue['name']}' matched domething that was matched by some other rule before on this failure: {result['failure_message']}"
                                )
                            results[issue["name"]] += 1
                            matched = True
                    if not matched:
                        logging.error(
                            f"No rule matched on this error: {result['failure_message']}"
                        )
                        results["TODO"] += 1
    return results


def print_stats(results):
    for issue_name, result in sorted(
        results.items(), reverse=True, key=lambda item: item[1]
    ):
        print(f"\t{result}\t{issue_name}")


def find_log_files(dirname):
    """
    List log files in directory structure like this:

        workdir-exporter-jenkins-csb-perf.apps.ocp-c1.prod.psi.redhat.com/workspace/Sat_Red/run-2022-09-08T20:36:48+00:00/regs-50-register-container-host-client-logs
        ├── f04-h23-b01-5039ms.rdu2.scalelab.redhat.com
        │   └── root
        │       ├── out-2022-09-08T22_20_16_00_00.log
        │       ├── out-2022-09-08T22_23_17_00_00.log
        │       ...
        ├── f09-h20-b07-5039ms.rdu2.scalelab.redhat.com
        │   └── root
        │       ├── out-2022-09-08T22_20_16_00_00.log
        │       ├── out-2022-09-08T22_23_17_00_00.log
        │       ...
        ...
    """
    results = collections.defaultdict(list)
    for dirname_host, dirnames, _ in os.walk(dirname):
        if "root" in dirnames:
            hostname = dirname_host.split("/")[-1]
            for dirname_final, dn, filenames in os.walk(
                os.path.join(dirname_host, "root")
            ):
                for f in filenames:
                    if f.startswith("out-") and os.path.splitext(f)[1] == ".log":
                        filename = os.path.join(dirname_final, f)
                        results[hostname].append(filename)
                results[hostname].sort()
    return results


def gather_stats(log_files):
    results = collections.defaultdict(list)
    for host, logs in log_files.items():
        logging.info(f"Processing {host}, which has {len(logs)} logs")
        for log_id, log in zip(range(len(logs)), logs):
            results[host].append(stats_for_file(log))
    return results


def summary_print(results, iterations):
    # Show stats per host
    print()
    for host, result_set in results.items():
        print(f"Stats for host {host}")
        print_stats(merge_results(*result_set))

    # Show stats per iteration
    print()
    for iteration in range(iterations):
        print(f"Stats for iteration {iteration + 1}")
        print_stats(
            merge_results(*[stats_set[iteration] for stats_set in results.values()])
        )

    # Show stats overall
    print()
    print("Stats overall")
    print_stats(
        merge_results(*[stats for stats_set in results.values() for stats in stats_set])
    )


def summary_dump_csv(results, iterations, output_file):
    header = set()
    for host, stats_set in results.items():
        for stats in stats_set:
            header = header | set(stats.keys())  # This "|" is union

    per_iteration = []
    for iteration in range(iterations):
        row = {"iteration": iteration + 1}
        row.update(
            merge_results(*[stats_set[iteration] for stats_set in results.values()])
        )
        per_iteration.append(row)

    with open(output_file, "w") as fd:
        header.discard("OK")
        header.discard("TODO")
        w = csv.DictWriter(
            fd,
            fieldnames=["iteration", "OK"] + sorted(header) + ["TODO"],
            restval=0,
        )
        w.writeheader()
        for row in per_iteration:
            w.writerow(row)


log_files = find_log_files(sys.argv[1])
iterations = len(list(log_files.values())[0])
results = gather_stats(log_files)
summary_print(results, iterations)
summary_dump_csv(results, iterations, "file.csv")
