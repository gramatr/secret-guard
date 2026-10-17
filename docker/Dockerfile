# docker/Dockerfile
#
# Optional daemon mode (daemon/server.py), for deployments running
# secret-guard alongside pii-guard/injection-guard as one Docker
# Compose stack — see gramatr/guards-stack. The primary interface
# remains core/scan.sh invoked directly by an adapter; this image
# exists for interface consistency, not because scan.sh needed to
# become resident (gitleaks has no model-load cost to amortize).
#
# Base: the official gitleaks image, not python:3.12-slim + a manual
# binary download — gitleaks publishes its own image specifically so
# downstream Dockerfiles can copy the binary out of it rather than
# re-implementing "detect the right release asset for this arch."
FROM ghcr.io/gitleaks/gitleaks:v8.30.1 AS gitleaks

FROM python:3.12-slim
COPY --from=gitleaks /usr/bin/gitleaks /usr/bin/gitleaks
RUN apt-get update && apt-get install -y --no-install-recommends jq bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY core/ ./core/
COPY daemon/ ./daemon/
RUN chmod +x core/scan.sh

# Binding 0.0.0.0 is only correct INSIDE Docker's isolated network
# namespace — the port-publish step on whatever composes this image
# controls who can actually reach it from the host. Same split as
# pii-guard/injection-guard's own Dockerfiles between their config
# default (127.0.0.1) and this build-time override.
ENV SECRET_GUARD_HOST=0.0.0.0
ENV SECRET_GUARD_PORT=8732

EXPOSE 8732

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8732/health', timeout=3)" || exit 1

CMD ["python", "daemon/server.py"]
