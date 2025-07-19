import subprocess
from fastapi import FastAPI, Query, Response
from fastapi.responses import PlainTextResponse
from utils.exporter import export_metrics

app = FastAPI()

BASH_SCRIPT = "/app/utils/nexus_metrics_exporter.sh"


@app.get("/", response_class=PlainTextResponse)
def read_root():
    return "FastAPI Nexus Metrics Exporter"


@app.get("/metrics", response_class=PlainTextResponse)
def metrics(window: str = Query("1h", regex=r"^\d+[hH]$"), sh: bool = Query(False)):
    """
    window: Time window string like '1h', '12h', '24h', '48h'. Default is '1h'.
    sh: If true, execute shell script. If false, use Python function.
    """
    if sh:
        # Run shell script
        cmd = [BASH_SCRIPT, window]
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = proc.communicate(timeout=60)
        if proc.returncode != 0:
            return Response(err, media_type="text/plain; version=0.0.4")
        return Response(out, media_type="text/plain; version=0.0.4")
    else:
        # Use Python exporter function
        try:
            metrics_output = export_metrics(window)
            return Response(metrics_output, media_type="text/plain; version=0.0.4")
        except Exception as e:
            return Response(str(e), media_type="text/plain; version=0.0.4")
