# Echo — Roadmap

> Aggiornata al 13/10/2026. Stato dettagliato, bug noti e prossimi passi: [PROJECT-STATUS.md](PROJECT-STATUS.md).
> La fase attuale è la core beta ([spec](superpowers/specs/2026-10-01-core-beta-design.md)).

## Fase 1: MVP ✅ (completata)

Il vertical slice end-to-end è implementato:

- [x] Firmware ESP32-S3 (VAD + ADPCM + HTTP POST + PSRAM buffer + NTP)
- [x] Backend FastAPI (ingest audio + STT + entity extraction + RAG query)
- [x] Database PostgreSQL + pgvector (schema completo)
- [x] Background worker (STT → analisi → chunking → embeddings)
- [x] Web UI (chat + sidebar conversazioni + dettaglio entità)
- [x] Deduplicazione entità
- [x] Retention audio 30 giorni
- [x] Provider abstraction (STT, LLM, Embeddings)
- [x] Documentazione (CONTEXT.md, 5 ADR, README, schema.sql)
- [x] Docker Compose (full stack + infra-only per dev locale)

## Fase 2: Stabilizzazione e test (in corso: core beta)

Obiettivo: il sistema funziona in modo affidabile per un utente reale.

### 2.1 — Test hardware
- [ ] Flash firmware sul XIAO ESP32-S3 Sense reale
- [ ] Calibrare soglia VAD nell'ambiente reale (ufficio, casa)
- [ ] Verificare durata batteria effettiva
- [ ] Test range Wi-Fi e comportamento buffer PSRAM

### 2.2 — Test backend end-to-end
- [ ] Deploy su macchina personale (Linux/Mac con Docker)
- [ ] Inviare audio reale dal device → verificare trascrizione
- [ ] Verificare entity extraction su conversazioni italiane reali
- [ ] Verificare qualità RAG con domande sulla memoria

### 2.3 — Bug fix e robustezza
- [x] Gestione errori nel worker (retry, dead letter queue)
- [x] Logging strutturato (JSON logs)
- [ ] Graceful shutdown del worker (parziale: i task vengono cancellati e il lavoro in corso rimesso in coda, senza attesa)
- [x] Timeout e circuit breaker per chiamate OpenAI
- [ ] Validazione input più rigorosa sugli endpoint

### 2.4 — Test automatizzati
- [x] Integration test con DB reale (service container Postgres/Redis in CI)
- [x] Mock OpenAI per test senza API key
- [x] CI pipeline (GitHub Actions; niente CD, l'app Flutter non è in CI)

## Fase 3: Miglioramenti core

Obiettivo: il "secondo cervello" diventa realmente utile.

### 3.1 — Qualità della memoria
- [x] Contesto persone note nel prompt di entity extraction
- [ ] Speaker diarization (oggi solo stima per energia: self/other/unknown, correggibile a mano)
- [x] Riassunti giornalieri automatici (digest) e per conversazione — settimanali da fare
- [x] Deduplicazione migliorata con merge semantico
- [x] Linking temporale ("ieri", "la settimana scorsa")

### 3.2 — Query avanzate
- [x] Filtri per data nella query ("questa settimana", "ieri")
- [ ] Filtri per persona ("cosa ha detto Marco?")
- [ ] Filtri per tipo entità ("mostrami tutti i task aperti")
- [x] Follow-up conversazionali (contesto multi-turn)

### 3.3 — UX
- [ ] Notifiche task estratti (push notification)
- [x] Feedback utente sulla qualità delle risposte
- [x] Cronologia query nella web UI
- [x] Dark/light mode toggle
- [ ] Export conversazioni (markdown, PDF)

## Fase 4: Mobile e multi-device

Obiettivo: usabilità fuori casa/ufficio.

### 4.1 — App mobile companion
- [x] App Flutter (iOS-first)
- [x] BLE connection al wearable
- [x] Forward audio al backend via internet
- [x] UI per query, conversazioni, entità
- [ ] Push notifications per task/promemoria

### 4.2 — Firmware avanzato
- [ ] OTA firmware updates
- [x] BLE come trasporto alternativo
- [ ] Wake word opzionale
- [ ] Power optimization (light sleep tra frames VAD)
- [ ] Feedback aptico/sonoro

## Fase 5: Integrazioni e automazioni

Obiettivo: il secondo cervello agisce nel mondo.

### 5.1 — Integrazioni (MCP / Function Calling)
- [x] Google Calendar (crea/leggi eventi)
- [ ] Gmail (bozze, riassunti)
- [ ] Slack/Teams (oggi solo invio su webhook Slack)
- [x] Notion (crea pagine) — Obsidian da fare
- [ ] GitHub/Jira (crea issue da task estratti)
- [ ] Home Assistant (controllo smart home)
- [ ] Todoist/TickTick (oggi solo creazione task Todoist, niente sync)

### 5.2 — Automazioni
- [x] Regole utente: "quando sento un task, crealo su Todoist"
- [ ] Promemoria automatici basati su contesto
- [ ] Riassunto giornaliero via email
- [ ] Action suggestions ("Vuoi che crei un evento per la conferenza?")

## Fase 6: Multi-provider e self-hosting

Obiettivo: indipendenza da OpenAI, privacy totale.

### 6.1 — Provider alternativi
- [ ] Whisper self-hosted (faster-whisper su GPU)
- [ ] LLM locale (Ollama, llama.cpp)
- [ ] Embeddings locali (sentence-transformers)
- [ ] Anthropic Claude come alternativa
- [ ] Google Gemini come alternativa

### 6.2 — Deploy options
- [ ] One-click deploy su VPS (script Ansible/Terraform)
- [ ] Docker Compose production-ready (TLS, backups)
- [ ] Kubernetes Helm chart (per utenti avanzati)
- [ ] Documentazione self-hosting completa

## Fase 7: Multi-utente e piattaforma

Obiettivo: altri possono usare il sistema.

- [ ] User registration e auth (OAuth2)
- [ ] Multi-utente con isolamento dati
- [ ] Device management (pairing, multiple devices)
- [ ] Plugin system per integrazioni di terze parti
- [ ] API pubblica documentata
- [ ] Marketplace plugin
- [ ] Landing page e documentazione pubblica

---

## Priorità immediata

1. **Test di 2 ore della core beta** su iPhone con build release: [BETA-GATE-CHECKLIST.md](BETA-GATE-CHECKLIST.md).
2. **Calibrazione VAD e misura consumi** sul device reale (soglia oggi fissa a 500).
3. **Prima settimana d'uso reale**: qualità di trascrizioni, entità e risposte RAG su conversazioni italiane.
