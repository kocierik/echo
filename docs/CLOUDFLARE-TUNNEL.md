# Cloudflare Tunnel Setup

Esponi il backend Echo su internet senza aprire porte sul router: l'app (e con lei il wearable, via BLE) lo raggiunge da qualsiasi rete.

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
| `echo` | `man.ovh` | `http://api:8000` |

Questo crea `echo.man.ovh` → il tuo backend.

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
curl https://echo.man.ovh/health
# Dovrebbe ritornare {"status":"ok","postgres":"ok","redis":"ok",...}
```

### 6. Configura l'app e il simulatore

Nell'app il server URL è già `https://echo.man.ovh` (onboarding, o Settings → Connection). Il wearable
non parla con il backend: manda l'audio al telefono via BLE e l'app lo inoltra.

Nel simulatore:
```bash
python simulate_device.py -s https://echo.man.ovh -k <api-key>
```

## Sicurezza

- TLS fino a Cloudflare, nessuna porta aperta sul router, filtro DDoS di Cloudflare.
- **L'API key è l'unica protezione degli endpoint**: con il backend su internet non usare mai la chiave
  di esempio `my-secret-key` del README (è pubblica). Crea una chiave casuale con `make create-key`,
  mettila nell'app, poi elimina quella di esempio con `make revoke-example-key`. `make deploy` avvisa
  se è ancora attiva.
- Il tunnel raggiunge `api` sulla rete interna di Docker: le porte pubblicate da `docker-compose.yml`
  ascoltano solo su `127.0.0.1`. Una porta aperta sulla LAN permetterebbe di falsificare
  `CF-Connecting-IP`, che il limite sui tentativi con API key sbagliata usa per riconoscere il client.

## Costi

**Gratis.** Cloudflare Tunnel è incluso nel piano gratuito per un numero ragionevole di richieste (illimitate per uso personale).

## Troubleshooting

```bash
# Controlla i log del tunnel
docker compose logs tunnel

# Errore "token invalid": verifica che CLOUDFLARE_TUNNEL_TOKEN sia corretto nel .env
# Errore "connection refused": verifica che il servizio api sia in esecuzione
```
