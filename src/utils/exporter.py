# exporter.py
import re
import gzip
from datetime import datetime, timedelta
from pathlib import Path
from collections import Counter
from prometheus_client import (
    CollectorRegistry,
    generate_latest,
    Counter as PCounter,
    Gauge,
)

LOG_DIR = Path("/nexus-data/log")
LOG_PATTERN = re.compile(r"\[(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})")
MONTHS = {
    "Jan": 1,
    "Feb": 2,
    "Mar": 3,
    "Apr": 4,
    "May": 5,
    "Jun": 6,
    "Jul": 7,
    "Aug": 8,
    "Sep": 9,
    "Oct": 10,
    "Nov": 11,
    "Dec": 12,
}


# ─── Helpers ─────────────────────────────────
def parse_line_time(line):
    """Extract a datetime from an nginx‐style log line, or return None."""
    m = LOG_PATTERN.search(line)
    if not m:
        return None
    day, mon, year, hh, mm, ss = m.groups()
    return datetime(int(year), MONTHS[mon], int(day), int(hh), int(mm), int(ss))


def iter_log_file(path, cutoff):
    """Yield each line in `path` with timestamp >= cutoff."""
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", errors="ignore") as f:
        for line in f:
            ts = parse_line_time(line)
            if ts and ts >= cutoff:
                yield line


def collect_metrics(window_hours):
    """Scan logs from the past `window_hours` and return aggregated counters."""
    cutoff = datetime.now() - timedelta(hours=window_hours)
    # Determine which dates to scan
    dates = set()
    # from cutoff day to today
    day = cutoff.date()
    while day <= datetime.now().date():
        dates.add(day.strftime("%Y-%m-%d"))
        day += timedelta(days=1)

    # Prepare counters
    total = 0
    by_user = Counter()
    by_endpoint = Counter()
    by_repo = Counter()
    by_service = Counter()
    by_ip = Counter()
    by_hour = Counter()
    by_status = Counter()
    custom_flags = Counter()

    # load flags if any
    flags = []
    flag_file = Path("/opt/scripts/flags.txt")
    if flag_file.exists():
        flags = [l.strip() for l in flag_file.read_text().splitlines() if l.strip()]

    # scan archives & live log
    for d in sorted(dates):
        for suffix in [".log.gz", ".log"]:
            p = LOG_DIR / f"request-{d}{suffix}"
            if p.exists():
                for line in iter_log_file(p, cutoff):
                    total += 1
                    parts = line.split()
                    ip = parts[0]
                    user = parts[2]
                    status = parts[8] if len(parts) > 8 else ""
                    by_ip[ip] += 1
                    by_user[user] += 1
                    by_status[status] += 1
                    # endpoint + repo + service
                    # assumes the request part is in quotes: "METHOD /path HTTP/1.x"
                    try:
                        req = line.split('"')[1]
                        method, path, _ = req.split()
                        by_endpoint[path] += 1
                        if path.startswith("/repository/"):
                            repo = "/" + "/".join(path.split("/")[1:3])
                            by_repo[repo] += 1
                        if path.startswith("/service/"):
                            svc = "/" + "/".join(path.split("/")[1:3])
                            by_service[svc] += 1
                    except:
                        pass

                    # hour
                    ts = parse_line_time(line)
                    if ts:
                        by_hour[f"{ts.hour:02d}"] += 1
                    # custom flags
                    for flag in flags:
                        if flag in line:
                            custom_flags[flag] += 1
    # live log
    live = LOG_DIR / "request.log"
    if live.exists():
        for line in iter_log_file(live, cutoff):
            # same accumulation as above…
            total += 1
            parts = line.split()
            ip = parts[0]
            user = parts[2]
            status = parts[8] if len(parts) > 8 else ""
            by_ip[ip] += 1
            by_user[user] += 1
            by_status[status] += 1
            try:
                req = line.split('"')[1]
                method, path, _ = req.split()
                by_endpoint[path] += 1
                if path.startswith("/repository/"):
                    repo = "/" + "/".join(path.split("/")[1:3])
                    by_repo[repo] += 1
                if path.startswith("/service/"):
                    svc = "/" + "/".join(path.split("/")[1:3])
                    by_service[svc] += 1
            except:
                pass

            ts = parse_line_time(line)
            if ts:
                by_hour[f"{ts.hour:02d}"] += 1
            for flag in flags:
                if flag in line:
                    custom_flags[flag] += 1
    return {
        "total": total,
        "by_user": by_user,
        "by_endpoint": by_endpoint,
        "by_repo": by_repo,
        "by_service": by_service,
        "by_ip": by_ip,
        "by_hour": by_hour,
        "by_status": by_status,
        "custom_flags": custom_flags,
    }


# ─── Main ─────────────────────────────────
def export_metrics(window: str) -> bytes:
    """Generate Prometheus‐formatted metrics for the last `window` (e.g. '6h')."""
    hours = int(window.rstrip("h"))
    data = collect_metrics(hours)
    reg = CollectorRegistry()

    # define metrics
    PCounter(
        "nexus_exporter_api_requests_total",
        f"Total API requests in last {window}",
        registry=reg,
    ).inc(data["total"])

    # static retrieve for the last 24h total hits ignoring the window.
    data24 = collect_metrics(24)
    g24 = Gauge(
        "nexus_exporter_api_requests_total_last_24h",
        "Total API requests in the last 24h",
        registry=reg,
    )
    g24.set(data24["total"])

    gu = Gauge(
        "nexus_exporter_requests_by_user",
        f"Requests by user in last {window}",
        ["user"],
        registry=reg,
    )
    for u, c in data["by_user"].items():
        gu.labels(user=u).set(c)

    ge = Gauge(
        "nexus_exporter_api_requests_by_endpoint",
        f"Requests by endpoint in last {window}",
        ["endpoint"],
        registry=reg,
    )
    for p, c in data["by_endpoint"].most_common(50):
        ge.labels(endpoint=p).set(c)

    gr = Gauge(
        "nexus_exporter_api_requests_by_repository",
        f"Requests by repository in last {window}",
        ["repository"],
        registry=reg,
    )
    for r, c in data["by_repo"].items():
        gr.labels(repository=r).set(c)

    gs = Gauge(
        "nexus_exporter_api_requests_by_service",
        f"Requests by service in last {window}",
        ["service"],
        registry=reg,
    )
    for s, c in data["by_service"].items():
        gs.labels(service=s).set(c)

    gi = Gauge(
        "nexus_exporter_api_requests_by_source_ip",
        f"Requests by IP in last {window}",
        ["ip"],
        registry=reg,
    )
    for ip, c in data["by_ip"].items():
        gi.labels(ip=ip).set(c)

    gh = Gauge(
        "nexus_exporter_api_requests_by_hour",
        f"Requests by hour in last {window}",
        ["hour"],
        registry=reg,
    )
    for h, c in data["by_hour"].items():
        gh.labels(hour=h).set(c)

    gsc = Gauge(
        "nexus_exporter_api_status_code_total",
        f"Status code distribution in last {window}",
        ["code"],
        registry=reg,
    )
    for code, c in data["by_status"].items():
        gsc.labels(code=code).set(c)

    gf = Gauge(
        "nexus_exporter_api_custom_flag_matches",
        f"Custom flag matches in last {window}",
        ["flag"],
        registry=reg,
    )
    for f, c in data["custom_flags"].items():
        gf.labels(flag=f).set(c)

    payload = generate_latest(reg)

    return payload
