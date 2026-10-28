FROM python:3.11-slim@sha256:ae952e0a57138a4317b9b61caaa19a8217c2f356803f8d7e63aad08769950937
RUN apt-get update && apt-get install -y --no-install-recommends docker-cli git openssh-client ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
COPY static ./static
ENV PYTHONUNBUFFERED=1
HEALTHCHECK --interval=20s --timeout=5s CMD python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8070/health", timeout=3)'
CMD ["python", "server.py"]
