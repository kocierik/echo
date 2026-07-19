# Cloudflare Tunnel Setup

Esponi il backend Echo su internet senza aprire porte sul router. Il device si connette ovunque ci sia Wi-Fi.

## Prerequisiti

- Account Cloudflare (gratuito)
- Un dominio su Cloudflare (anche gratuito con .tk/.ml o economico)
- Docker in esecuzione

## Setup (una volta sola, ~5 minuti)

### 1. Crea il tunnel

1. Vai su https://one.dash.cloudflare.com
2. **Networks → Tunnels → Create a tunnel**
3. Scegli **Cloudflared** come connector
4. Dai un nome (es. `echo`)
5. Copia il **tunnel token** che appare

### 2. Configura il routing

Nella pagina del tunnel, sezione **Public Hostnames**:

| Subdomain | Domain | Service |
|-----------|--------|---------|
| `echo` | `tuodominio.com` | `http://api:8000` |

Questo crea `echo.tuodominio.com` → il tuo backend.

### 3. Aggiungi il token al .env

```bash
# Nel file .env
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiNjRkZ...il-tuo-token...
```

### 4. Avvia tutto con Docker Compose

```bash
docker compose up -d
```

Il servizio `tunnel` nel `docker-compose.yml` si connetterà automaticamente a Cloudflare.

### 5. Verifica

```bash
curl https://echo.tuodominio.com/health
# Dovrebbe ritornare: {"status":"ok","postgres":"ok","redis":"ok"}
```

### 6. Configura il device

Nel firmware `config.h`:
```c
#define SERVER_HOST "echo.tuodominio.com"
#define SERVER_PORT 443
#define SERVER_ENDPOINT "/api/segments"
```

E nel `http_sender.h`, cambia `http://` in `https://` (Cloudflare gestisce il TLS).

Nel simulatore:
```bash
python simulate_device.py -s https://echo.tuodominio.com
```

## Sicurezza

Il tunnel è già sicuro:
- TLS end-to-end (Cloudflare termina HTTPS)
- Nessuna porta aperta sul router
- L'API key protegge gli endpoint
- Cloudflare filtra attacchi DDoS

## Costi

**Gratis.** Cloudflare Tunnel è incluso nel piano gratuito per un numero ragionevole di richieste (illimitate per uso personale).

## Troubleshooting

```bash
# Controlla i log del tunnel
docker compose logs tunnel

# Errore "token invalid": verifica che CLOUDFLARE_TUNNEL_TOKEN sia corretto nel .env
# Errore "connection refused": verifica che il servizio api sia in esecuzione
```
