# Built with repo root as build context (see docker-compose.yml), so this
# can reach the shared requirements.txt at the repo root.
FROM python:3.12.7-slim

WORKDIR /app

# Shared dependencies (Flask + requests) - same requirements.txt used by all
# three services, kept in one place instead of duplicated per service.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# curl is only here for the HEALTHCHECK below (and for manual debugging
# inside the container); the app itself uses the stdlib + requests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY services/ride-api/*.py ./

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser

EXPOSE 3001

HEALTHCHECK --interval=5s --timeout=3s --retries=5 --start-period=5s \
    CMD curl -fs http://localhost:3001/health || exit 1

CMD ["python", "app.py"]
