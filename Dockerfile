# Base images are pinned by digest (@sha256): the tag is only a label.
# To update one: docker buildx imagetools inspect <tag> and paste the new digest.
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

RUN apk add --no-cache bash curl jq bind-tools

WORKDIR /app

COPY toggle-proxy.sh entrypoint.sh ./
RUN chmod +x toggle-proxy.sh entrypoint.sh

RUN mkdir -p /app/logs /app/state

# Intervalo en segundos entre ejecuciones (por defecto 5 min)
ENV CHECK_INTERVAL=300

# Unhealthy si el bucle lleva más de 3 intervalos sin dar una vuelta
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=2 \
  CMD sh -c 'test $(( $(date +%s) - $(stat -c %Y /tmp/heartbeat) )) -lt $(( ${CHECK_INTERVAL:-300} * 3 ))'

ENTRYPOINT ["./entrypoint.sh"]
