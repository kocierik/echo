# Echo — Roadmap

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

## Fase 2: Stabilizzazione e test (prossima)

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
- [ ] Gestione errori nel worker (retry, dead letter queue)
- [ ] Logging strutturato (JSON logs)
- [ ] Graceful shutdown del worker
- [ ] Timeout e circuit breaker per chiamate OpenAI
- [ ] Validazione input più rigorosa sugli endpoint

### 2.4 — Test automatizzati
- [ ] Integration test con DB reale (testcontainers)
- [ ] Mock OpenAI per test senza API key
- [ ] CI/CD pipeline (GitHub Actions)

## Fase 3: Miglioramenti core

Obiettivo: il "secondo cervello" diventa realmente utile.

### 3.1 — Qualità della memoria
- [ ] Contesto persone note nel prompt di entity extraction
- [ ] Speaker diarization (distinguere chi parla)
- [ ] Riassunti giornalieri/settimanali automatici
- [ ] Deduplicazione migliorata con merge semantico
- [ ] Linking temporale ("ieri", "la settimana scorsa")

### 3.2 — Query avanzate
- [ ] Filtri per data nella query ("questa settimana", "ieri")
- [ ] Filtri per persona ("cosa ha detto Marco?")
- [ ] Filtri per tipo entità ("mostrami tutti i task aperti")
- [ ] Follow-up conversazionali (contesto multi-turn)

### 3.3 — UX
- [ ] Notifiche task estratti (push notification)
- [ ] Feedback utente sulla qualità delle risposte
- [ ] Cronologia query nella web UI
- [ ] Dark/light mode toggle
- [ ] Export conversazioni (markdown, PDF)

## Fase 4: Mobile e multi-device

Obiettivo: usabilità fuori casa/ufficio.

### 4.1 — App mobile companion
- [ ] React Native o Flutter app
- [ ] BLE connection al wearable
- [ ] Forward audio al backend via internet
- [ ] UI per query, conversazioni, entità
- [ ] Push notifications per task/promemoria

### 4.2 — Firmware avanzato
- [ ] OTA firmware updates
- [ ] BLE come trasporto alternativo
- [ ] Wake word opzionale
- [ ] Power optimization (light sleep tra frames VAD)
- [ ] Feedback aptico/sonoro

## Fase 5: Integrazioni e automazioni

Obiettivo: il secondo cervello agisce nel mondo.

### 5.1 — Integrazioni (MCP / Function Calling)
- [ ] Google Calendar (crea/leggi eventi)
- [ ] Gmail (bozze, riassunti)
- [ ] Slack/Teams (messaggi, riassunti canali)
- [ ] Notion/Obsidian (crea note)
- [ ] GitHub/Jira (crea issue da task estratti)
- [ ] Home Assistant (controllo smart home)
- [ ] Todoist/TickTick (sync task)

### 5.2 — Automazioni
- [ ] Regole utente: "quando sento un task, crealo su Todoist"
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

## Priorità immediata (prossimi 7 giorni)

1. **Flash e test hardware** — verificare che il firmware funzioni sul device reale
2. **Deploy su macchina personale** — Docker Compose funzionante senza firewall
3. **Prima conversazione reale** — parlare, trascrivere, queryare

Tutto il resto può aspettare finché il flusso end-to-end non è verificato su hardware reale.
