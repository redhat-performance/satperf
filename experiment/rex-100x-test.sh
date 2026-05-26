#!/bin/bash

# REX Memory Leak Reproduction Test
# Runs REX jobs repeatedly with big output to reproduce foreman-proxy memory leak
#
# This test reproduces the memory leak issue where foreman-proxy RSS grows over time
# when executing scaled REX jobs. The issue is caused by foreman-proxy keeping task
# outcomes in memory, which are purged every 24 hours by default.
#
# Usage:
#   ./experiment/rex-memory-leak.sh
#
# Configuration (via environment variables):
#   PARAM_rex_iterations=100           - Number of REX jobs to run (default: 100)
#   PARAM_rex_job_template=<name>      - Job template to use (default: "Run Command - SSH Default")
#   PARAM_rex_command_type=<type>      - Command type: system-info-dump, package-list, log-analysis, heavy-load, custom
#   PARAM_rex_custom_command=<cmd>     - Custom command when using command_type=custom
#   PARAM_rex_search_query=<query>     - Host search query (default: "name ~ container")
#   PARAM_rex_abort_on_failure=true    - Abort if failure rate exceeds threshold (default: true)
#   PARAM_rex_failure_threshold=20     - Failure rate % threshold for abort (default: 20)
#
# Examples:
#   # Run 200 iterations with heavy load
#   PARAM_rex_iterations=200 PARAM_rex_command_type=heavy-load ./experiment/rex-memory-leak.sh
#
#   # Run with custom command
#   PARAM_rex_command_type=custom \
#   PARAM_rex_custom_command='for i in {1..2000}; do echo "Line $i"; done' \
#   ./experiment/rex-memory-leak.sh

source experiment/run-library.sh

# Configuration
REX_ITERATIONS="${PARAM_rex_iterations:-100}"
REX_JOB_TEMPLATE="${PARAM_rex_job_template:-Run Command - SSH Default}"
REX_COMMAND_TYPE="${PARAM_rex_command_type:-system-info-dump}"
REX_SEARCH_QUERY="${PARAM_rex_search_query:-name ~ container}"
REX_CUSTOM_COMMAND="${PARAM_rex_custom_command:-}"
REX_ABORT_ON_FAILURE="${PARAM_rex_abort_on_failure:-true}"
REX_FAILURE_THRESHOLD="${PARAM_rex_failure_threshold:-20}"  # Abort if >20% failures

# Get command based on type
function get_command_for_type() {
    case "$REX_COMMAND_TYPE" in
        system-info-dump)
            echo "cat /proc/meminfo /proc/cpuinfo; dmesg | tail -500; rpm -qa | sort; ps auxf; df -h; ip a; ss -tuln; systemctl list-units --type=service"
            ;;
        package-list)
            echo "rpm -qa --queryformat '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SIZE}|%{INSTALLTIME}|%{SUMMARY}\n' | sort"
            ;;
        log-analysis)
            echo "journalctl --since '24 hours ago' --no-pager | tail -n 5000; tail -n 1000 /var/log/messages 2>/dev/null"
            ;;
        heavy-load)
            echo "echo '=== SYSTEM ==='; cat /proc/meminfo /proc/cpuinfo; echo '=== PACKAGES ==='; rpm -qa; echo '=== PROCESSES ==='; ps auxf; echo '=== LOGS ==='; journalctl -n 2000 --no-pager"
            ;;
        custom)
            echo "$REX_CUSTOM_COMMAND"
            ;;
        *)
            echo "date"
            ;;
    esac
}

# Get foreman-proxy memory (RSS in KB)
function get_proxy_memory() {
    ps aux | grep -E '(smart-proxy|foreman-proxy)' | grep -v grep | awk '{print $6}' | head -1
}

section 'Checking environment'
generic_environment_check false false

section "REX Memory Leak Test - $REX_ITERATIONS iterations"

# Get command to execute
command="$(get_command_for_type)"

log "Test configuration:"
log "  Iterations: $REX_ITERATIONS"
log "  Job template: $REX_JOB_TEMPLATE"
log "  Command type: $REX_COMMAND_TYPE"
log "  Search query: $REX_SEARCH_QUERY"
log "  Abort on failure: $REX_ABORT_ON_FAILURE (threshold: ${REX_FAILURE_THRESHOLD}%)"
log "  Command preview: ${command:0:100}..."

# Verify command is not empty
if [[ -z "$command" ]]; then
    log "ERROR: Command is empty! Check REX_COMMAND_TYPE or REX_CUSTOM_COMMAND"
    exit 1
fi

# Capture initial memory
initial_memory=$(get_proxy_memory)

# Validate foreman-proxy is running
if [[ -z "$initial_memory" ]]; then
    log "ERROR: foreman-proxy process not found! Is the service running?"
    log "Please start foreman-proxy service and try again."
    exit 1
fi

log "Initial foreman-proxy memory: ${initial_memory} KB ($(( initial_memory / 1024 )) MB)"

# Initialize memory tracking CSV
memory_csv="$logs/memory-tracking.csv"
echo "iteration,timestamp,rss_kb,delta_kb,cumulative_growth_kb" > "$memory_csv"

# Track statistics
success_count=0
fail_count=0
peak_memory=$initial_memory
total_start=$(date +%s)

# Main execution loop
for i in $(seq 1 $REX_ITERATIONS); do
    percent=$(( i * 100 / REX_ITERATIONS ))
    log "===== Iteration $i/$REX_ITERATIONS ($percent%) ====="

    # Capture memory before job
    mem_before=$(get_proxy_memory)

    # Execute REX job with properly escaped command
    h "rex-memory-leak-iter-${i}.log" \
      "job-invocation create --async \
       --description-format 'Memory leak test $i (%{template_name})' \
       --inputs command=\"\$command\" \
       --job-template '$REX_JOB_TEMPLATE' \
       --search-query '$REX_SEARCH_QUERY'"

    # Wait for job completion
    if jsr "$logs/rex-memory-leak-iter-${i}.log"; then
        ((success_count++))
    else
        ((fail_count++))
        log "WARNING: Iteration $i failed"
    fi

    # Examine job metrics
    j "$logs/rex-memory-leak-iter-${i}.log" || true

    # Capture memory after job
    mem_after=$(get_proxy_memory)

    # Handle case where foreman-proxy might have crashed/restarted
    if [[ -z "$mem_after" ]]; then
        log "ERROR: foreman-proxy process not found after iteration $i!"
        mem_after=$mem_before
    fi

    mem_delta=$((mem_after - mem_before))
    cumulative_growth=$((mem_after - initial_memory))

    # Track peak memory
    if (( mem_after > peak_memory )); then
        peak_memory=$mem_after
        log "New peak memory: ${peak_memory}KB ($(( peak_memory / 1024 ))MB)"
    fi

    # Write to CSV
    echo "$i,$(date -u +%s),$mem_after,$mem_delta,$cumulative_growth" >> "$memory_csv"

    log "Memory: before=${mem_before}KB, after=${mem_after}KB, delta=${mem_delta}KB, total_growth=${cumulative_growth}KB"

    # Check failure rate and abort if too high
    if $REX_ABORT_ON_FAILURE && (( i >= 10 )); then
        failure_rate=$(( fail_count * 100 / i ))
        if (( failure_rate > REX_FAILURE_THRESHOLD )); then
            log "ERROR: Failure rate ${failure_rate}% exceeds threshold ${REX_FAILURE_THRESHOLD}%"
            log "Aborting test after $i iterations"
            break
        fi
    fi

    # Log progress every 10 iterations
    if (( i % 10 == 0 )); then
        log "Progress: $percent% ($i/$REX_ITERATIONS completed), Memory growth: ${cumulative_growth}KB ($(( cumulative_growth / 1024 ))MB)"
    fi
done

# Final statistics
total_end=$(date +%s)
total_duration=$((total_end - total_start))
final_memory=$(get_proxy_memory)
memory_leaked=$((final_memory - initial_memory))

section 'Test Summary'
log "===== REX Memory Leak Test Summary ====="
log "Configuration:"
log "  Iterations Planned: $REX_ITERATIONS"
log "  Iterations Completed: $(( success_count + fail_count ))"
log "  Job Template: $REX_JOB_TEMPLATE"
log "  Command Type: $REX_COMMAND_TYPE"
log ""
log "Memory Analysis:"
log "  Initial RSS: ${initial_memory} KB ($(( initial_memory / 1024 )) MB)"
log "  Final RSS: ${final_memory} KB ($(( final_memory / 1024 )) MB)"
log "  Peak RSS: ${peak_memory} KB ($(( peak_memory / 1024 )) MB)"
log "  Memory Leaked: ${memory_leaked} KB ($(( memory_leaked / 1024 )) MB)"
completed_iterations=$(( success_count + fail_count ))
if (( completed_iterations > 0 )); then
    log "  Growth Rate: $(( memory_leaked / completed_iterations )) KB/iteration"
fi
log ""
log "Execution Results:"
log "  Total Duration: ${total_duration} seconds"
log "  Successful Jobs: ${success_count}/${completed_iterations}"
log "  Failed Jobs: ${fail_count}/${completed_iterations}"
if (( fail_count > 0 )); then
    log "  Failure Rate: $(( fail_count * 100 / completed_iterations ))%"
fi
if (( success_count > 0 )); then
    log "  Average Duration: $(( total_duration / success_count )) seconds/job"
fi
log ""
log "Output Files:"
log "  Memory CSV: $memory_csv"
log "  Summary: $logs/memory-summary.txt"
log "  Individual logs: $logs/rex-memory-leak-iter-*.log"

# Save summary to file
summary_file="$logs/memory-summary.txt"
cat > "$summary_file" <<EOF
=== REX Memory Leak Test Summary ===
Test Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Configuration:
  Iterations Planned: $REX_ITERATIONS
  Iterations Completed: ${completed_iterations}
  Job Template: $REX_JOB_TEMPLATE
  Command Type: $REX_COMMAND_TYPE
  Search Query: $REX_SEARCH_QUERY

Memory Analysis:
  Initial RSS: ${initial_memory} KB ($(( initial_memory / 1024 )) MB)
  Final RSS: ${final_memory} KB ($(( final_memory / 1024 )) MB)
  Peak RSS: ${peak_memory} KB ($(( peak_memory / 1024 )) MB)
  Memory Leaked: ${memory_leaked} KB ($(( memory_leaked / 1024 )) MB)
  Growth Rate: $(( completed_iterations > 0 ? memory_leaked / completed_iterations : 0 )) KB/iteration

Execution Results:
  Total Duration: ${total_duration} seconds
  Successful Jobs: ${success_count}/${completed_iterations}
  Failed Jobs: ${fail_count}/${completed_iterations}
  Failure Rate: $(( completed_iterations > 0 ? fail_count * 100 / completed_iterations : 0 ))%
  Average Duration: $(( success_count > 0 ? total_duration / success_count : 0 )) seconds/job

Output Files:
  Memory CSV: $memory_csv
  Individual Logs: $logs/rex-memory-leak-iter-*.log
EOF

log "Summary saved to: $summary_file"
log "Memory tracking CSV saved to: $memory_csv"

junit_upload
