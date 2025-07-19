# Keep an Eye on Your NEXUS Limits - Monitoring Sonatype Nexus Usage


## Introduction
Imagine rolling into work Monday morning, kicking off your CI/CD pipeline… and halfway through, builds start failing because Nexus has silently blocked you. 😱   
That’s what happens when you hit the Sonatype Nexus free Community Edition quotas (**100 000 components**, **200 000 requests/day**) without warning.


Below, we'll buit a lightweight monitoring mechanism to alert us before we hit those caps and help us analyze and optimize Nexus component usage and API traffic. Through parsing Nexus logs with an exporter and scraping it with Prometheus 

## Why We Needed Custom Metrics Exporter
The Nexus Community Edition is fantastic, but its usage limits can be a real headache. without monitoring your usage, you risk:

  * CI jobs randomly failing
  * Developers scratching their heads at timeouts
  * Emergency “Nexus upgrade” firefights

Nexus Community Edition does expose by default a Prometheus endpoint at `/service/metrics/prometheus` with many gauges and counters. but the only actionable metric we could reliably use was the **total number of components**. We need real-time counters also on **API hits**, broken down into:
1. **Total Requests**: Count the total number of requests.
2. **Requests Per User**: Aggregate requests by user.
3. **Top Requested Endpoints**: Identify the most requested endpoints.
4. **Requests Per Repository**: Aggregate requests by repository.
5. **Requests Per Service**: Aggregate requests by service.
6. **Requests Per Source IP**: Aggregate requests by source IP.
7. **Requests Per Hour**: Aggregate requests by hour.
8. **Status Code Distribution**: Count requests by status code.

everything a good SRE NERD loves. They might be either missing or buried behind undocumented internal names we couldn’t map.
<br><br>  
## 📝 1. Extracting Metrics from Nexus Logs with Bash

#### 📂 What Data Lives in the Logs?
A typical Nexus request log line might look like:
```log
2025-06-25 14:12:03,456 INFO  [qtp123456-78] org.sonatype.nexus.Repository - GET /repository/maven-central/org/foo/bar/1.0/bar-1.0.jar 200 user=jdoe ip=192.0.2.5
```
Nexus store its live logs at `/nexus-data/log/request.log` and archive the daily logs as `request-YYYY-MM-DD.log{,.gz}`

#### 🛠️ Bash Script Essentials
1. **Usage & Time Window**  
   Select time window & validate with a default last 24h window
    ```bash
    WINDOW="${1:-24h}"
    NUM=${WINDOW%h}

    # Validate
    if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
    echo "ERROR: window must be like 1h,12h,24h,48h" >&2
    exit 2
    fi

    CUTOFF=$(date -d "-${NUM} hour" +%s)
    ```

2. **Scanning & Filtering Logs**  
    Collect the window logs from the past archives and live logs at /tmp/filterd.log and load it, using `scan_file()` helper that do the following:  
      1.	Reads a log file (handles both plain and .gz).
      2.	Parses each line’s timestamp, converts it to seconds.
      3.	Prints only lines newer than the cutoff.
    
    ```bash
    # Helper: emit only lines newer than cutoff
    scan_file() {
    file="$1"
    if [ "${file%.gz}" != "$file" ]; then
    zcat "$file"
    else
    cat "$file"
    fi | awk -v cutoff=$CUTOFF '
    {
        sub(/^\[/,"",$4)
        split($4, a, /[\/:]/)
        day=a[1]; mon=a[2]; year=a[3]; hour=a[4]; min=a[5]; sec=a[6]
        m["Jan"]=1; m["Feb"]=2; m["Mar"]=3; m["Apr"]=4
        m["May"]=5; m["Jun"]=6; m["Jul"]=7; m["Aug"]=8
        m["Sep"]=9; m["Oct"]=10; m["Nov"]=11; m["Dec"]=12
        ts = mktime(year " " m[mon] " " day " " hour " " min " " sec)
        if (ts >= cutoff) print
    }'
    }

    set +o pipefail
    {
    # 1) Scan archives from START_DAY → yesterday
    current="$START_DAY"
    while [[ "$current" != "$TODAY" ]]; do
        for ext in gz ""; do
        F="$LOG_DIR/request-$current.log${ext:+.$ext}"
        [[ -f $F ]] && scan_file "$F"
        done
        current=$(date -d "$current +1 day" +%Y-%m-%d)
    done

    # 2) Then scan the live log
    scan_file "$LIVE_LOG"
    } > /tmp/filtered.log
    set -o pipefail

    LOG_CONTENT=$(cat "/tmp/filtered.log")
    ```

3. **Aggregating Metrics**  
    Once you have `/tmp/filtered.log`, the script uses simple text-processing (awk, grep)s and pipelines to count metrics.  
    > Each pipeline ends by formatting results as Prometheus metrics, e.g.:
    > ```pom
    > nexus_custom_exporter_api_requests_by_user{user="jdoe"} 123
    > ```

    ```bash
    # ——————— 1. Total Requests ——————————————————————
    TOTAL_REQUESTS=$(echo "$LOG_CONTENT" | wc -l)

    # ——————— 2. Requests Per User —————————————————————
    USER_METRICS=$(echo "$LOG_CONTENT" \
    | awk '{print $3}' \
    | sort | uniq -c \
    | awk '{ printf("nexus_custom_exporter_api_requests_by_user{user=\"%s\"} %d\n",$2,$1) }')

    # ——————— 3. Top 50 Requested Endpoints ——————————————————
    set +o pipefail
    ENDPOINT_METRICS=$(echo "$LOG_CONTENT" \
    | awk -F'"' '{print $2}' \
    | awk '{print $2}' \
    | sort | uniq -c \
    | sort -nr \
    | head -n 50 \
    | awk '{ printf("nexus_custom_exporter_api_requests_by_endpoint{endpoint=\"%s\"} %d\n",$2,$1) }')

    set -o pipefail

    # ——————— 4. Requests Per Repository ——————————————
    REPO_METRICS=$(echo "$LOG_CONTENT" \
    | awk -F'"' '{print $2}' \
    | awk '{print $2}' \
    | grep "^/repository/" \
    | awk -F'/' '{print "/"$2"/"$3}' \
    | sort | uniq -c \
    | awk '{ repo=$2; for(i=3;i<=NF;i++) repo=repo"/"$i; printf("nexus_custom_exporter_api_requests_by_repository{repository=\"%s\"} %d\n",repo,$1) }')

    # ——————— 5. Requests Per Service ——————————————————
    SERVICE_METRICS=$(echo "$LOG_CONTENT" \
    | awk -F'"' '{print $2}' \
    | awk '{print $2}' \
    | grep "^/service/" \
    | awk -F'/' '{print "/"$2"/"$3}' \
    | sort | uniq -c \
    | awk '{ printf("nexus_custom_exporter_api_requests_by_service{service=\"%s\"} %d\n",$2,$1) }')

    # ——————— 6. Requests Per Source IP —————————————————
    IP_METRICS=$(echo "$LOG_CONTENT" \
    | awk '{print $1}' \
    | sort | uniq -c \
    | awk '{ printf("nexus_custom_exporter_api_requests_by_source_ip{ip=\"%s\"} %d\n",$2,$1) }')

    # ——————— 7. Requests Per Hour ————————————————————
    HOUR_METRICS=$(echo "$LOG_CONTENT" \
    | awk -F'[:[]' '{print $3}' \
    | sort | uniq -c \
    | awk '{ printf("nexus_custom_exporter_api_requests_by_hour{hour=\"%02d\"} %d\n",$2,$1) }')

    # ——————— 8. Status Code Distribution —————————————
    STATUS_METRICS=$(echo "$LOG_CONTENT" \
    | awk '{print $9}' \
    | sort | uniq -c \
    | awk '{ printf("nexus_custom_exporter_api_status_code_total{code=\"%s\"} %d\n",$2,$1) }')

    ```

4. **Emitting Prometheus Exposition**  
    Finally, the script writes out `/app/nexus_api_hits.prom`
    ```bash
    cat <<EOF > "$OUT_FILE"
    # HELP nexus_custom_exporter_api_requests_total Total number of Nexus REST API requests in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_total counter
    nexus_custom_exporter_api_requests_total ${TOTAL_REQUESTS}

    # HELP nexus_custom_exporter_api_requests_by_user Number of Nexus API requests per user in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_by_user gauge
    ${USER_METRICS}

    # HELP nexus_custom_exporter_api_requests_by_endpoint Number of Nexus API requests per endpoint in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_by_endpoint gauge
    ${ENDPOINT_METRICS}

    # HELP nexus_custom_exporter_api_requests_by_repository Number of Nexus API requests per repository in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_by_repository gauge
    ${REPO_METRICS}

    # HELP nexus_custom_exporter_api_requests_by_service Number of Nexus API requests per service path in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_by_service gauge
    ${SERVICE_METRICS}

    # HELP nexus_custom_exporter_api_requests_by_source_ip Number of Nexus API requests per source IP in last ${NUM}h
    # TYPE nexus_custom_exporter_api_requests_by_source_ip gauge
    ${IP_METRICS}

    # HELP nexus_custom_exporter_api_requests_by_hour Number of Nexus API requests per hour in last ${NUM}h (UTC)
    # TYPE nexus_custom_exporter_api_requests_by_hour gauge
    ${HOUR_METRICS}

    # HELP nexus_custom_exporter_api_status_code_total Number of Nexus API responses by HTTP status code in last ${NUM}h
    # TYPE nexus_custom_exporter_api_status_code_total counter
    ${STATUS_METRICS}

    # HELP nexus_custom_exporter_api_custom_flag_matches Number of log lines matching custom flags in last ${NUM}h
    # TYPE nexus_custom_exporter_api_custom_flag_matches gauge
    ${FLAG_METRICS}
    EOF

    cat $OUT_FILE
    ```

**With these building blocks, our script reads logs, filters a 24 h window, and spits out neat Prometheus-style metrics.**


> 📂 **Grab the Full Script**  
> I’ve published the complete, ready-to-run script on GitHub [Here](https://github.com/Hesham-14/Sonatype-Nexus-Usage-Monitoring.git)  
> Feel free to clone, tweak the log paths, add your own flags, or submit a PR with improvements! 

<br><br>  
## 🌐 2. Wrapping the Script in a FastAPI Server
Next, we'll wrap our Bash script in a FastAPI sidecar. This will allow Prometheus to scrape our metrics endpoint. Here's a basic example:

```python
import subprocess
from fastapi import FastAPI, Query, Response
from fastapi.responses import PlainTextResponse

app = FastAPI()

BASH_SCRIPT = "/app/utils/nexus_metrics_exporter.sh"


@app.get("/", response_class=PlainTextResponse)
def read_root():
    return "FastAPI Nexus Metrics Exporter"


@app.get("/metrics", response_class=PlainTextResponse)
def metrics(window: str = Query("1h", regex=r"^\d+[hH]$")):
    """
    window: Time window string like '1h', '12h', '24h', '48h'. Default is '1h'.
    """
    # Run shell script
    cmd = [BASH_SCRIPT, window]
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate(timeout=60)
    if proc.returncode != 0:
        return Response(err, media_type="text/plain; version=0.0.4")
    return Response(out, media_type="text/plain; version=0.0.4")
```

## 📦 3. Docker Image and Kubernetes Sidecar Deployment
Now, let's create a Docker image for our FastAPI sidecar and deploy it as a Kubernetes sidecar or standalone container.


```dockerfile
FROM python:3.9-slim
WORKDIR /app
COPY . .
RUN pip install fastapi uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

We can build & deploy as a container on our Nexus server:
```bash
docker build -t <nexus-metrics-exporter-image>:<build-tag> .
docker run -d --name nexus-metrics-exporter -p 8080:8080 -v /data/nexus-external/sonatype-work/nexus3:/nexus-data <nexus-metrics-exporter-image>:<build-tag>
```

Or if your nexus is running on k8s, add this into its deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus
  labels:
    app: nexus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus
  template:
    metadata:
      labels:
        app: nexus
        metrics-exporter: "true"
    spec:
     containers:
       - name: nexus
          # your nexus container config

       - name: nexus-metrics-exporter
          image: <nexus-metrics-exporter-image>:<build-tag>
         ports:
         - name: metrics
           containerPort: 8080
        volumeMounts:
         - name: nexus-storage
           mountPath: /nexus-data
        volumes:
            # This volume corresponds to your sonatype_path 
        - name: nexus-storage
          hostPath:
            path: /data/nexus-external/sonatype-work/nexus3
            type: DirectoryOrCreate
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: nexus-metrics-exporter-service
  namespace: nexus-ns
  labels:
    app: nexus
    metrics-exporter: "true"
spec:
  selector:
    app: nexus
    metrics-exporter: "true"
  type: NodePort
  ports:
    - name: metrics
      targetPort: 8080
      port: 8080
      nodePort: 30097
```

## 📊 Configuring Prometheus’s scrape_config

IF you are running **Kube-prometheus-stack**, deploy this scrape job into your prometheus namespace:
```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  labels:
    release: prometheus
    scrape-config: enable
  name: nexus-external-custom-metrics-scrape
  namespace: prometheus
spec:
  jobName: nexus_usage_scrape_job
  scrapeInterval: 1h
  scrapeTimeout: 15s
  scheme: HTTP
  metricsPath: /metrics
  staticConfigs:
    - targets:
      - exporter-fastapi-server:30097
```
Deploy it and reload Prometheus, then hit **Status → Targets** to confirm your exporter is up.

Check Your metrics in prometheus wwith the following example:

```promql
sum_over_time(nexus_exporter_api_requests_total[24h])
```

You can graph these metrics in Grafana, set alerts on high-volume hits or error spikes, and get proactive warnings before Nexus slams the door shut on your CICD.

Happy monitoring! 🚀
