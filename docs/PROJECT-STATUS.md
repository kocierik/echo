# Echo — Stato del progetto (13/10/2026)

Analisi della codebase: cosa c'è, cosa funziona, cosa è rotto e cosa manca.
Prima analisi su `main` @ `5b235d0`; aggiornato dopo le correzioni sul branch `fix/core-beta-review`.

---

## 1. Cos'è Echo

Wearable "second brain": un pendente ESP32-S3 ascolta, registra solo quando rileva voce, manda l'audio
al telefono via BLE; l'app lo inoltra a un backend self-hosted che trascrive, estrae entità
(persone, task, idee, eventi, note), costruisce una memoria vettoriale e risponde a domande in linguaggio naturale (RAG).

```
XIAO ESP32-S3 Sense ──BLE (ADPCM, frame + CRC)──▶ App Flutter (iOS-first) ──HTTP──▶ FastAPI
  VAD + pre-buffer                                 relay, upload, UI                  │ Redis queues
  PSRAM ring buffer 512KB                                                             ▼
  mute persistente (NVS)                                                    Worker: STT → speaker → analisi
                                                                            → entità → chunk/embedding
                                                                            → integrazioni/regole
                                                                            + riassunti, digest, retention
                                                                                      ▼
                                                                         PostgreSQL + pgvector
```

| Componente | Tecnologia | Test |
|---|---|---|
| `firmware/` | Arduino + NimBLE 2.3.2, PlatformIO | 8 suite Unity native (protocollo, stato transfer, bond, mute, overflow, ring buffer) |
| `mobile/` | Flutter (flutter_blue_plus, secure storage, local notifications) | ~25 file di test (servizi + widget) |
| `backend/` | FastAPI async, SQLAlchemy, Redis, OpenAI | ~30 file pytest (unitari + integrazione con Postgres) |
| `backend/static/` | Web UI vanilla (chat + admin) | — |
| `simulator/` | Python, simula il device via HTTP | — |

Fase attuale: **Core Beta** ([spec](superpowers/specs/2026-10-01-core-beta-design.md)): un utente, un iPhone,
un wearable, un backend. Le tre tranche (device reliability, memory controls, mobile experience) sono mergiate;
**il gate della beta (test continuo di 2 ore su iPhone) non è ancora stato eseguito**: checklist in
[BETA-GATE-CHECKLIST.md](BETA-GATE-CHECKLIST.md).

---

## 2. Funzionalità implementate

### Firmware
- Cattura PDM 16 kHz, VAD a soglia di energia (fissa a 500), pre-buffer ~500 ms per non perdere l'inizio parola.
- Encoding IMA-ADPCM 4:1, segmenti max 6 s / 120 KB.
- Ring buffer PSRAM 512 KB con politica **drop-oldest** e contatore dei segmenti persi.
- Trasporto BLE a frame: finestre di ACK, restart segmento, `UPLOAD_OK` come unico dequeue, CRC32 ([ADR 0006](adr/0006-ble-relay-through-phone.md)).
- BLE Secure Connections + bonding con un solo peer; `FORGET_BOND`; caratteristiche cifrate.
- `SET_TIME` (ancora temporale dal telefono), `SET_MUTED` persistente in NVS, `DEVICE_STATUS` v2, `DEVICE_INFO`.

### App mobile
- Onboarding a 4 step (server/API key → permessi → pairing → fine).
- Tab Today / Transcripts / Ask + Settings (Device, Connection, Privacy, Automations, Diagnostics, About).
- **Today:** stato wearable, ultima trascrizione, **task aperti (completabili)**, **riassunto del giorno**, pausa/ripresa.
- Relay BLE con riassemblaggio pacchetti, riconnessione automatica con backoff, restore state iOS (`bluetooth-central`).
- Policy di rete (Wi-Fi only opzionale), notifiche locali (disconnessione, perdita audio, upload falliti).
- Transcript raggruppati per giorno con ricerca, correzione testo/speaker, eliminazione conversazione.
- Ask: chat con storico sessioni completo, feedback 👍/👎, input vocale, markdown.
- Rules e Integrations (Google Calendar via OAuth), tema chiaro/scuro, errori API tipizzati, logout.

### Backend
- `POST /api/segments`: ingest idempotente (hash audio + `recorded_at`), limite 5 MB, rate limit 60/min.
- Worker: STT (OpenAI `gpt-4o-transcribe` o Deepgram) con prompt contestuale, pulizia testo, filtro trascrizioni banali,
  classificazione speaker per energia, retry esponenziale + circuit breaker + dead letter queue.
- Analisi: conversazioni separate da silenzio del device, **buco di tempo reale** o **durata massima (2 h)**;
  estrazione entità con contesto persone note e **date/orari/durate risolti rispetto al giorno della registrazione**;
  consolidamento + dedup fuzzy/LLM, chunk incrementali con embedding.
- **Titoli e riassunti per conversazione** generati in modo asincrono a conversazione chiusa (`workers/summaries.py`).
- RAG `POST /api/query`: filtro temporale da linguaggio naturale (IT/EN) o esplicito (anche aperto), ricerca vettoriale
  chunk + entità, re-ranking da feedback, follow-up multi-turn; storico completo in Postgres, contesto ricaricato se Redis è scaduto.
- Azioni da chat su Google Calendar: elenco, creazione (durata detta o 1 h di default), modifica e cancellazione
  indicando l'evento per nome (e giorno), con domanda di chiarimento se più eventi corrispondono; la modifica conserva
  giorno/ora/durata non cambiati. Il classificatore dell'intento parte solo per richieste che sembrano di calendario.
- Correzione trascrizione con audit + rianalisi in coda con lock distribuito, **senza side effect** su integrazioni e regole.
- Eliminazione conversazione a cascata; retention audio (completati 24 h, incompleti 7 giorni).
- Digest giornaliero automatico (alle 4:00 locali, per il giorno appena finito), CRUD entità/task, merge entità, regole utente, integrazioni
  (Todoist, Google Calendar, Notion, Telegram, Slack, webhook), OAuth Google con `state` firmato e monouso,
  `/health`, `/metrics` Prometheus, admin DLQ (anche per le rianalisi).

---

## 3. Problemi

### Risolti il 13/10/2026 (branch `fix/core-beta-review`)

| # | Problema | Commit |
|---|---|---|
| 1 | La rianalisi (modifica in staging) scatenava integrazioni e regole, duplicando eventi/task | tolta, nessun commit necessario |
| 2 | Storico chat sovrascritto dalla history Redis (scadenza 30 min, max 20 messaggi) | `6eb2c9d` |
| 3 | Progetti nativi iOS/Android ignorati da git | `a591b1e` (ma vanno rigenerati: vedi §4) |
| 4 | Eventi "tutto il giorno" rifiutati da Google (fine = inizio) | `6eb2c9d` |
| 5 | Eventi automatici senza orario e con date non ISO | `e231d95` |
| 6 | DLQ: voci di rianalisi mandavano in 500 elenco e retry, e venivano perse | `6eb2c9d` |
| 7 | Il refresh del token Calendar faceva commit a metà dell'analisi | `e231d95` |
| 8 | OAuth Google senza protezione CSRF (`state` = user_id in chiaro); errore riflesso non escapato | `18d963a` |
| 9 | Filtri data espliciti aperti mandavano in crash `/query`; `session_id` non UUID → 500 | `18d963a`, `6eb2c9d` |
| 12 | Conversazioni infinite se il device non misurava mai 2 min di silenzio | `2f7e4d5` |
| 13 | Titoli/riassunti delle conversazioni mai generati | `2f7e4d5` |
| — | Spostare un evento da chat ne azzerava la durata; cambiare solo l'orario non aveva effetto | `e231d95` |
| — | Test `test_analysis_pipeline_preserves_normal_call_order` rotto su `main` | `2f7e4d5` |
| 10 | La condizione `speaker` delle regole non matchava mai | `fb1d8eb` |
| 14 | Calendario e digest con confini del giorno in UTC; digest con un giorno di ritardo | `fd36b64`, `fb1d8eb` |
| 15 | Modifica/cancellazione eventi da chat richiedevano un `event_id` mai visto dal modello | `fd36b64` |
| 16 | Due chiamate a GPT-4o per ogni domanda sulla memoria | `fd36b64` |
| 17 | `/api/stats` e `/metrics` senza autenticazione, conteggi globali | `fb1d8eb` |
| — | CI rossa: 60 errori ruff; `speaker_detector.py` e il suo test incollati due volte (la copia peggiore vinceva) | `0d09920` |

### Ancora aperti

**Medi**

11. **Classificazione speaker probabilmente invertita.** Soglia al 70° percentile ([speaker_detector.py:34](../backend/app/services/speaker_detector.py#L34)):
    solo ~30% dei segmenti diventa "self", mentre il commento dice che la voce dell'utente domina. Da verificare con dati reali.
12b. **Filtri temporali per `started_at`.** RAG e digest filtrano le conversazioni per inizio: con il limite di 2 h il problema
    è ridotto, ma una conversazione a cavallo della mezzanotte finisce tutta nel giorno d'inizio.
18. **Shutdown del worker non "graceful":** i task vengono cancellati subito ([workers/main.py:652](../backend/app/workers/main.py#L652)); il lavoro interrotto viene rimesso in coda.
19. **Lingua mista:** UI mobile in inglese, risposte backend, prompt, prefissi speaker e messaggi d'errore in italiano.
20. **Todoist REST v2** ([engine.py:92](../backend/app/integrations/engine.py#L92), [rules_engine.py:242](../backend/app/services/rules_engine.py#L242)):
    l'API v2 è stata deprecata in favore della v1 unificata; verificare che risponda ancora.

### Ambiente di sviluppo e CI
- `ruff check app/ tests/` è pulito. La CI ora ha anche il job `mobile` (`flutter analyze` + `flutter test`) e i test nativi
  del firmware (`pio test -e native`): **nessuno dei due è ancora girato** e potrebbero far emergere problemi preesistenti.
- I test di integrazione con Postgres (step "Integration tests" della CI) non sono stati eseguiti in locale: qui Docker/Podman
  non sono attivi.
- **Test backend su Windows:** `asyncpg==0.29` non ha wheel per Python 3.13 e richiede MSVC. Usare Python 3.11 (come la CI) o Docker.
  Per i test unitari basta un venv 3.13 con `asyncpg>=0.30` e `pytest --noconftest`.
- **`uv.lock` non aggiornato** per la nuova dipendenza `tzdata` (Docker e CI installano da `pyproject.toml` con pip, quindi non si rompono):
  rigenerarlo con `uv lock` quando conviene (la versione di uv installata qui riscrive il formato del file).
- I test Flutter scritti il 13/10 **non sono stati eseguiti** in locale (SDK non disponibile): li lancerà il nuovo job CI.

---

## 4. Cosa manca

### Rispetto alla spec Core Beta
| Requisito | Stato |
|---|---|
| Test continuo di 2 h su iPhone (foreground/background/locked) | ❌ da eseguire: [checklist](BETA-GATE-CHECKLIST.md) |
| Test batteria 12 h | ⏸ rimandato finché non arriva l'hardware |
| Today: task aperti + riassunto giornaliero | ✅ (test widget da eseguire) |
| Storico chat completo e riprendibile | ✅ |
| Rianalisi senza side effect | ✅ |
| Build iOS release riproducibile | ⚠️ `.gitignore` corretto, ma il progetto Xcode/Gradle va rigenerato con `flutter create` e committato ([mobile/README.md](../mobile/README.md)) |
| Diagnostica del limite di consolidamento cross-conversazione | ❓ non trovata in UI |

### Dalla roadmap (ancora aperti)
- **Hardware reale:** calibrazione VAD (soglia fissa, nessuna adattiva), misura consumi, range BLE.
- **Memoria:** diarization vera (oggi solo energia), riassunti settimanali, raggruppamento conversazioni per argomento.
- **Query:** filtri per persona ("cosa ha detto Marco?") e per tipo di entità nel RAG.
- **Firmware:** OTA, mute fisico (GPIO presente ma inutilizzato), lettura batteria (sempre 255), storage offline su microSD.
- **Provider alternativi:** solo OpenAI (LLM/embedding) e OpenAI/Deepgram (STT); niente modelli locali né Anthropic/Gemini.
- **Fase Composio** (adapter integrazioni, conferma in-app delle azioni, audit): non iniziata.
- **Multi-utente / OAuth login:** fuori scope beta; l'API key si crea ancora a mano via SQL.
- **Android in background:** non è un gate della beta.

---

## 5. Debito tecnico

- **Integrazioni duplicate:** `integrations/engine.py` e `rules_engine.py` reimplementano gli stessi client (Todoist, Notion,
  Telegram, Slack); il refresh del token in `engine.py` non salva il nuovo token. Sarà sostituito dall'adapter Composio.
- **Schema DB doppio:** `docs/schema.sql` + `alembic stamp head` al primo avvio invece di `alembic upgrade head` da zero.
- **Rate limiting per IP** dietro Cloudflare Tunnel: tutte le richieste arrivano dallo stesso IP.
- Script sparsi in root (`fix_dns_test.sh`, `setup_and_test.sh`, `start_api.sh`, `test_api.sh`, `run_backend.sh`) legati al workaround del PC aziendale.
- `mobile/ios/Flutter/flutter_export_environment.sh` è versionato ma è generato e contiene percorsi locali.
- Fatto il 13/10: rimosso il codice morto (firmware Wi-Fi/NTP, 7 file mobile) e aggiornati README, ROADMAP,
  ADR (nuovo [0006](adr/0006-ble-relay-through-phone.md), 0001 superato) e note di stato dei piani.

---

## 6. Prossimi passi consigliati

1. **Rigenerare e committare i progetti nativi** (`flutter create --platforms=ios,android .` in `mobile/`) e lanciare `flutter test`
   (o pushare e guardare il nuovo job CI `mobile`).
2. **Eseguire il test di 2 ore della beta** con la [checklist](BETA-GATE-CHECKLIST.md): è il blocco per chiudere la fase.
3. **Calibrare VAD e soglia speaker** (#11) con le prime registrazioni reali: soglia VAD fissa a 500, percentile speaker al 70°.
4. **Filtri temporali per sovrapposizione** (#12b): filtrare conversazioni per intervallo `[started_at, ended_at]` invece che per inizio.
5. **Shutdown graceful del worker** (#18): attendere fino a 30 s il lavoro in corso prima di cancellare i task.
6. Uniformare la lingua (#19) e verificare l'API Todoist (#20).
