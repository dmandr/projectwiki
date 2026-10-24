FROM python:3.12-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates poppler-utils && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock
COPY *.py ./
ENV PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false HF_HUB_DISABLE_TELEMETRY=1
HEALTHCHECK --interval=20s --timeout=5s --start-period=30s CMD python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8090/health", timeout=3)'
CMD ["python", "service.py"]
