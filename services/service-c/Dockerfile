# Built with repo root as build context (see docker-compose.yml), so this
# can reach the shared requirements.txt at the repo root.
FROM python:3.12.7-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY services/service-c/app.py .

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser

EXPOSE 3003

HEALTHCHECK --interval=5s --timeout=3s --retries=5 --start-period=5s \
    CMD curl -fs http://localhost:3003/health || exit 1

CMD ["python", "app.py"]
