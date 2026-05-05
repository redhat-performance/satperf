#!/bin/bash
# Registration performance monitor
# Works on both foreman-installer (native) and foremanctl (containerized) deployments
# Polls: Puma stats, PG wait events, Candlepin/Tomcat threads, network connections
# Usage: registration-monitor-full.sh [interval_seconds] [output_dir]

INTERVAL=${1:-2}
OUTDIR=${2:-/root/reg-monitor}
mkdir -p "$OUTDIR"

# Auto-detect deployment mode
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^foreman$'; then
    MODE="container"
else
    MODE="native"
fi

echo "# registration-monitor started at $(date -Iseconds) mode=$MODE" | tee "$OUTDIR/README"
echo "# interval=${INTERVAL}s" >> "$OUTDIR/README"

# --- Output files ---
PUMA_LOG="$OUTDIR/puma.log"
echo "# ts backlog busy capacity requests" > "$PUMA_LOG"

PG_LOG="$OUTDIR/pg-summary.log"
echo "# ts active idle wait_io wait_lock wait_lwlock wait_client foreman_conns candlepin_conns" > "$PG_LOG"

PG_DETAIL="$OUTDIR/pg-waits.log"
echo "# ts datname wait_event_type wait_event state count" > "$PG_DETAIL"

NET_LOG="$OUTDIR/net-conns.log"
if [ "$MODE" = "container" ]; then
    echo "# ts httpd_443 candlepin_23443 candlepin_tw postgres_5432 puma_3000" > "$NET_LOG"
else
    echo "# ts httpd_443 candlepin_23443 candlepin_tw postgres_5432 foreman_sock" > "$NET_LOG"
fi

TOMCAT_LOG="$OUTDIR/tomcat-threads.log"
echo "# ts total_threads handler_threads" > "$TOMCAT_LOG"

# --- PG Queries ---
PG_SUMMARY_QUERY="SELECT
    coalesce(sum(case when state='active' then 1 else 0 end), 0),
    coalesce(sum(case when state='idle' then 1 else 0 end), 0),
    coalesce(sum(case when wait_event_type='IO' and state='active' then 1 else 0 end), 0),
    coalesce(sum(case when wait_event_type='Lock' and state='active' then 1 else 0 end), 0),
    coalesce(sum(case when wait_event_type='LWLock' and state='active' then 1 else 0 end), 0),
    coalesce(sum(case when wait_event_type='Client' then 1 else 0 end), 0),
    coalesce(sum(case when datname='foreman' then 1 else 0 end), 0),
    coalesce(sum(case when datname='candlepin' then 1 else 0 end), 0)
FROM pg_stat_activity
WHERE datname IN ('foreman','candlepin')"

PG_DETAIL_QUERY="SELECT
    datname,
    coalesce(wait_event_type, 'CPU'),
    coalesce(wait_event, 'running'),
    state,
    count(*)
FROM pg_stat_activity
WHERE datname IN ('foreman','candlepin')
  AND state = 'active'
GROUP BY 1,2,3,4
ORDER BY 5 DESC"

# --- Helper: get Puma stats ---
get_puma_stats() {
    if [ "$MODE" = "container" ]; then
        podman exec foreman bash -c '
            AUTH_TOKEN=$(grep control_auth_token /var/run/foreman/puma.state 2>/dev/null | awk "{print \$2}")
            curl -s --unix-socket /usr/share/foreman/tmp/sockets/pumactl.sock "http://localhost/stats?token=$AUTH_TOKEN" 2>/dev/null
        ' 2>/dev/null
    else
        PUMA_STATE=/run/foreman/puma.state
        CONTROL_URL=$(grep control_url "$PUMA_STATE" 2>/dev/null | awk '{print $2}')
        AUTH_TOKEN=$(grep control_auth_token "$PUMA_STATE" 2>/dev/null | awk '{print $2}')
        pumactl stats -C "$CONTROL_URL" -T "$AUTH_TOKEN" 2>/dev/null
    fi
}

# --- Helper: query PG ---
pg_query() {
    if [ "$MODE" = "container" ]; then
        podman exec postgresql psql -U foreman -d foreman -t -A -F' ' -c "$1" 2>/dev/null
    else
        su - postgres -c "psql -t -A -F' ' -c \"$1\"" 2>/dev/null
    fi
}

# --- Helper: get Tomcat threads ---
get_tomcat_threads() {
    if [ "$MODE" = "container" ]; then
        podman exec candlepin bash -c '
            total=$(ls /proc/1/task/ 2>/dev/null | wc -l)
            handler=0
            for tid in $(ls /proc/1/task/ 2>/dev/null); do
                name=$(cat /proc/1/task/$tid/comm 2>/dev/null)
                case "$name" in https-jsse-*) handler=$((handler + 1));; esac
            done
            echo "$total $handler"
        ' 2>/dev/null
    else
        tomcat_pid=$(ss -tnlp src :23443 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
        if [ -n "$tomcat_pid" ]; then
            total=$(ls /proc/$tomcat_pid/task/ 2>/dev/null | wc -l)
            handler=0
            for tid in $(ls /proc/$tomcat_pid/task/ 2>/dev/null); do
                name=$(cat /proc/$tomcat_pid/task/$tid/comm 2>/dev/null)
                case "$name" in https-jsse-*) handler=$((handler + 1));; esac
            done
            echo "$total $handler"
        fi
    fi
}

# --- Helper: get network connections ---
get_net_conns() {
    httpd=$(ss -tnp state established '( dport = 443 or sport = 443 )' 2>/dev/null | tail -n +2 | wc -l)
    candlepin=$(ss -tnp state established '( dport = 23443 or sport = 23443 )' 2>/dev/null | tail -n +2 | wc -l)
    candlepin_tw=$(ss -tn state time-wait '( dport = 23443 or sport = 23443 )' 2>/dev/null | tail -n +2 | wc -l)
    postgres=$(ss -tnp state established '( dport = 5432 or sport = 5432 )' 2>/dev/null | tail -n +2 | wc -l)
    if [ "$MODE" = "container" ]; then
        puma_conns=$(ss -tnp state established '( dport = 3000 or sport = 3000 )' 2>/dev/null | tail -n +2 | wc -l)
    else
        puma_conns=$(ss -xp state established src /run/foreman.sock 2>/dev/null | tail -n +2 | wc -l)
    fi
    echo "$httpd $candlepin $candlepin_tw $postgres $puma_conns"
}

# --- Main loop ---
while true; do
    ts=$(date +%s.%N)

    # 1. Puma stats
    get_puma_stats | python3 -c '
import sys, json
try:
    for l in sys.stdin:
        l = l.strip()
        if l.startswith("{"):
            d = json.loads(l)
            total_backlog = sum(w["last_status"]["backlog"] for w in d["worker_status"])
            total_busy = sum(w["last_status"]["busy_threads"] for w in d["worker_status"])
            total_capacity = sum(w["last_status"]["pool_capacity"] for w in d["worker_status"])
            total_requests = sum(w["last_status"]["requests_count"] for w in d["worker_status"])
            print(f"{total_backlog} {total_busy} {total_capacity} {total_requests}")
            break
except:
    print("0 0 0 0")
' 2>/dev/null | while read puma; do
        echo "$ts $puma" >> "$PUMA_LOG"
    done

    # 2. PG summary
    pg_query "$PG_SUMMARY_QUERY" | while read pg; do echo "$ts $pg" >> "$PG_LOG"; done

    # 3. PG detailed waits
    pg_query "$PG_DETAIL_QUERY" | while read line; do
        [ -n "$line" ] && echo "$ts $line" >> "$PG_DETAIL"
    done

    # 4. Network connections
    echo "$ts $(get_net_conns)" >> "$NET_LOG"

    # 5. Candlepin/Tomcat threads
    tomcat_data=$(get_tomcat_threads)
    if [ -n "$tomcat_data" ]; then
        echo "$ts $tomcat_data" >> "$TOMCAT_LOG"
    fi

    sleep "$INTERVAL"
done
