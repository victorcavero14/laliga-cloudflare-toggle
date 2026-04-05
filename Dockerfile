FROM alpine:3.20

RUN apk add --no-cache bash curl jq bind-tools

WORKDIR /app

COPY toggle-proxy.sh entrypoint.sh ./
RUN chmod +x toggle-proxy.sh entrypoint.sh

RUN mkdir -p /app/logs /app/state

# Intervalo en segundos entre ejecuciones (por defecto 5 min)
ENV CHECK_INTERVAL=300

ENTRYPOINT ["./entrypoint.sh"]
