# laliga-cloudflare-toggle

> Tus webs usan Cloudflare y se caen cada vez que juega LaLiga? Este script lo arregla automaticamente.

Los ISPs espanoles bloquean IPs de Cloudflare durante los partidos de futbol. Si tu web usa el proxy de Cloudflare (nube naranja), **es inaccesible desde Espana** mientras dura el bloqueo.

Este script detecta los bloqueos en tiempo real y desactiva el proxy CDN automaticamente. Cuando el partido termina, lo reactiva. Sin intervencion manual.

---

## Como funciona

```
  Cada 5 min
      |
      v
 hayahora.futbol  ---->  Tus IPs bloqueadas?
      |                        |
     NO                       SI
      |                        |
  Todo OK              Quitar proxy CDN
                      (naranja -> gris)
                             |
                     Trafico va directo
                      a tu servidor
                             |
                    Cuando termine el
                    bloqueo, restaurar
                      proxy (-> naranja)
```

1. Consulta la API de [hayahora.futbol](https://hayahora.futbol/) para saber si hay bloqueo activo
2. Resuelve las IPs de **tus dominios** y comprueba si estan en la lista de bloqueados
3. Si lo estan, desactiva el proxy via Cloudflare API (nube naranja -> gris)
4. Cuando el bloqueo termina, reactiva el proxy exactamente como estaba

## Caracteristicas

- **Deteccion precisa**: solo actua si las IPs de tus dominios concretos estan bloqueadas (no un check generico)
- **Crash-safe**: state file se escribe tras cada operacion con escritura atomica (tmp + mv)
- **Idempotente**: ejecutar multiples veces no causa cambios innecesarios
- **Multi-dominio**: gestiona todos tus dominios de Cloudflare a la vez
- **Notificaciones Telegram**: avisa cuando desactiva y cuando reactiva
- **Lock file**: previene ejecuciones concurrentes
- **Timeout de seguridad**: si hayahora.futbol se cae, restaura el proxy tras 12h maximo
- **DRY_RUN**: modo prueba para verificar sin tocar nada
- **Docker ready**: Dockerfile incluido para desplegar en Coolify, Railway, etc.

## Quickstart

```bash
git clone https://github.com/victorcavero14/laliga-cloudflare-toggle.git
cd laliga-cloudflare-toggle

cp .env.example .env
# Editar .env con tu token de Cloudflare y dominios

chmod +x toggle-proxy.sh
./toggle-proxy.sh
```

## Configuracion

### 1. Token de Cloudflare

1. Ve a [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. **Create Token** > plantilla **Edit zone DNS**
3. **Zone Resources**: selecciona tus zonas (o todas)
4. Copia el token

### 2. Zone IDs

En el panel de Cloudflare de cada dominio > **Overview** > barra lateral derecha > **Zone ID**

### 3. Variables de entorno (.env)

```bash
# Cloudflare
CLOUDFLARE_API_TOKEN="tu_token"
DOMAINS="zone_id_1:dominio1.com,zone_id_2:dominio2.com"

# Telegram (opcional)
TELEGRAM_BOT_TOKEN="bot_token"
TELEGRAM_CHAT_ID="-123456789"

# Opciones
DRY_RUN=false            # true = solo detecta, no toca nada
CHECK_INTERVAL=300       # segundos entre checks (solo Docker)
MAX_DISABLED_HOURS=12    # maximo tiempo sin proxy si hayahora.futbol cae
```

El formato de `DOMAINS` es `ZONE_ID:DOMINIO` separados por comas. El script gestiona el dominio y todos sus subdominios.

## Despliegue

### Cron (VPS / servidor)

```bash
crontab -e
```

```
*/5 * * * * /ruta/a/laliga-cloudflare-toggle/toggle-proxy.sh >> /ruta/a/laliga-cloudflare-toggle/logs/cron.log 2>&1
```

### Docker / Coolify

```bash
docker build -t laliga-cloudflare-toggle .
docker run -d \
  -e CLOUDFLARE_API_TOKEN="tu_token" \
  -e DOMAINS="zone_id:dominio.com" \
  -e DRY_RUN=true \
  -v laliga-state:/app/state \
  laliga-cloudflare-toggle
```

En **Coolify**: crear recurso Docker, apuntar al repo, configurar variables de entorno desde la UI, y anadir volumen persistente `/app/state`.

> **Importante**: el volumen `/app/state` debe persistir entre redeploys para que el script sepa que registros desactivo.

## Que registros DNS modifica

| Criterio | Valor |
|---|---|
| Tipos | A, AAAA, CNAME |
| Scope | Dominio configurado + todos sus subdominios |
| Condicion | `proxiable: true` y actualmente `proxied: true` |
| Registros manuales en gris | Nunca se tocan |

## Seguridad ante fallos

| Escenario | Comportamiento |
|---|---|
| Crash mid-disable | State file tiene los registros ya cambiados. Siguiente ejecucion retoma el resto |
| Crash mid-enable | Registros rehabilitados se borran del state. Siguiente ejecucion retoma los pendientes |
| Ejecucion concurrente | Lock file con PID impide doble ejecucion |
| hayahora.futbol caido | No toca nada (fail-safe). Si el proxy lleva >12h desactivado, lo restaura por timeout |
| State file corrupto | Se trata como vacio. No rompe nada |
| Registro eliminado en Cloudflare | Log de error, continua con los demas |

## Estructura

```
laliga-cloudflare-toggle/
├── toggle-proxy.sh      # Script principal
├── entrypoint.sh        # Entrypoint Docker (loop cada CHECK_INTERVAL)
├── Dockerfile           # Alpine + bash + curl + jq + dig
├── .env.example         # Plantilla de configuracion
├── state/               # State files (persisten entre ejecuciones)
│   ├── proxy_disabled.json      # Registros desactivados por el script
│   └── proxy_disabled_ips.json  # IPs de Cloudflare guardadas
└── logs/                # Logs de ejecucion
    └── toggle-proxy.log
```

## Notificaciones Telegram

Configura `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` para recibir alertas:

**Cuando desactiva el proxy:**
> 🔴 **Proxy Cloudflare DESHABILITADO**
>
> LaLiga ha activado bloqueos. Se ha quitado el proxy en 12 registro(s):
> - A example.com -> 1.2.3.4
> - A www.example.com -> 1.2.3.4
> - ...

**Cuando lo reactiva:**
> 🟢 **Proxy Cloudflare REHABILITADO**
>
> El bloqueo ha terminado. Se ha restaurado el proxy en 12 registro(s).

## FAQ

### Solo afecta a webs en Espana?

El bloqueo lo hacen los ISPs espanoles (Movistar, Orange, Vodafone, DIGI, MasMovil). Usuarios de otros paises no se ven afectados. Al quitar el proxy CDN temporalmente, tus usuarios espanoles pueden acceder pero pierden la cache de Cloudflare durante el partido (~2-3h).

### Se pierde la cache de Cloudflare?

Si, durante el bloqueo el trafico va directo a tu servidor. Cuando el proxy se reactiva, la cache se reconstruye progresivamente.

### Que pasa si tengo registros que quiero mantener en gris?

El script solo desactiva registros que estan en naranja (proxied). Los que ya estan en gris nunca se tocan. Al rehabilitar, solo reactiva los que el mismo desactivo.

### Como se si mis IPs estan bloqueadas ahora?

Visita [hayahora.futbol](https://hayahora.futbol/) o ejecuta el script con `DRY_RUN=true`.

### Necesito dar de alta algo en hayahora.futbol?

No. La API es publica y gratuita. El script solo consulta `https://hayahora.futbol/estado/data.json`.

## Creditos

- [hayahora.futbol](https://hayahora.futbol/) - API de deteccion de bloqueos de LaLiga
- [Cloudflare API v4](https://developers.cloudflare.com/api/) - Gestion de DNS

## Licencia

MIT
