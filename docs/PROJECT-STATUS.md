# Echo — Stato del progetto (13/10/2026)

Analisi della codebase: cosa c'è, cosa funziona, cosa è rotto e cosa manca.
Prima analisi su `main` @ `5b235d0`; aggiornato dopo tre giri di correzioni, tutte committate su `main`.

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
- Integrations (Composio), tema chiaro/scuro, errori API tipizzati, logout.

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
- Azioni su app collegate (Gmail, Calendar...) via Composio: da chat e da richieste vocali "Echo, ...", con conferma in-app e audit.
  Sostituiscono le vecchie integrazioni automatiche, le regole e il client Google Calendar scritto a mano (rimossi).
- Correzione trascrizione con audit + rianalisi in coda con lock distribuito, senza chiamate esterne.
- Eliminazione conversazione a cascata; retention audio (completati 24 h, incompleti 7 giorni).
- Digest giornaliero automatico (alle 4:00 locali, per il giorno appena finito), CRUD entità/task, merge entità,
  `/health`, `/metrics` Prometheus, admin DLQ (anche per le rianalisi).

---

## 3. Problemi

### Risolti il 13/10/2026 (su `main`)

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
| 11 | Soglia speaker fissa al 70° percentile: ora `SPEAKER_THRESHOLD_PERCENTILE` (la calibrazione resta da fare) | `0fb07c8` |
| 12b | RAG e digest filtravano le conversazioni per inizio: ora per sovrapposizione col periodo | `0a4c248` |
| 18 | Allo shutdown il worker cancellava subito il lavoro in corso | `6c3b603` |
| 19 | Lingua mista: testi fissi in inglese, chat nella lingua della domanda, riassunti/digest in inglese, prefissi `[You]`/`[Others]` | `5633513` |
| 20 | Todoist REST v2 dismessa (410): passata all'API v1; client unificati per integrazioni e regole | `4cb25d7` |
| — | `POST /api/query/feedback` rispondeva sempre 500 (il 👍/👎 non funzionava) | `5633513` |
| — | Installazioni nuove senza la migrazione 006 (`schema.sql` + `stamp head`); `deploy.sh` nascondeva le migrazioni fallite | `3fbb621` |

### Ancora aperti

- **Speaker (#11):** la soglia ora è configurabile ma va calibrata su registrazioni reali.
- **Entità nella lingua parlata:** nomi e contenuti di task/eventi estratti restano nella lingua della trascrizione
  (di solito italiano), quindi in Today possono comparire task in italiano dentro un'app in inglese. Scelta voluta
  (tradurre perderebbe fedeltà e confonderebbe la deduplicazione): dimmi se preferisci tradurli.
- **Todoist v1 non verificata dal vivo:** l'endpoint `POST https://api.todoist.com/api/v1/tasks` e i campi usati vengono da
  note di migrazione di terze parti; la documentazione ufficiale è bloccata dal proxy aziendale. Da provare con un token reale.
- **Rilevamento lingua euristico:** per le risposte fisse (conferme calendario, "nessun risultato") si contano parole comuni
  italiane/inglesi; frasi molto brevi o miste cadono sull'inglese.

### Ambiente di sviluppo e CI
- `ruff check app/ tests/` è pulito. La CI ora ha anche il job `mobile` (`flutter analyze` + `flutter test`) e i test nativi
  del firmware (`pio test -e native`): **nessuno dei due è ancora girato** e potrebbero far emergere problemi preesistenti.
- I test di integrazione con Postgres (step "Integration tests" della CI) non sono stati eseguiti in locale: qui Docker/Podman
  non sono attivi.
- **Test backend su Windows:** `asyncpg==0.29` non ha wheel per Python 3.13 e richiede MSVC. Usare Python 3.11 (come la CI) o Docker.
  Per i test unitari basta un venv 3.13 con `asyncpg>=0.30` e `pytest --noconftest`.
- `uv.lock` rigenerato (era già disallineato da `pyproject.toml`; formato aggiornato da uv 0.9.5).
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
- **Fase Composio:** le integrazioni automatiche e le regole sono state sostituite dalle azioni Composio (conferma in-app,
  audit, richieste vocali "Echo, ..."); tabelle `rules`/`integrations` rimosse dalla migrazione 008.
- **Multi-utente / OAuth login:** fuori scope beta; l'API key si crea ancora a mano via SQL.
- **Android in background:** non è un gate della beta.

---

## 5. Debito tecnico

- **Schema DB doppio:** `docs/schema.sql` copre solo fino alla migrazione 005; le istruzioni ora fanno `stamp 001` +
  `upgrade head`, ma sarebbe più semplice creare il DB solo con Alembic (baseline 001 che crea davvero le tabelle).
- **Rate limiting per IP** dietro Cloudflare Tunnel: tutte le richieste arrivano dallo stesso IP.
- Fatto il 13/10: codice morto rimosso (firmware Wi-Fi/NTP, 7 file mobile, MessageBubble commentato), client delle
  integrazioni unificati, script del workaround aziendale rimossi, file generati da Flutter non più versionati,
  `uv.lock` rigenerato, README/ROADMAP/ADR/piani aggiornati.

---

## 6. Prossimi passi consigliati

**Per te** (servono hardware, SDK o account):

1. **Rigenerare e committare i progetti nativi** (`flutter create --platforms=ios,android .` in `mobile/`), poi
   `flutter test` o push per vedere i job CI `mobile` e firmware (mai girati).
2. **Controllare i test di integrazione con Postgres** in CI.
3. **Test di 2 ore della beta** con la [checklist](BETA-GATE-CHECKLIST.md).
4. **Calibrare** soglia VAD (`firmware/src/config.h`, oggi 500) e `SPEAKER_THRESHOLD_PERCENTILE` con registrazioni reali.
5. **Provare le azioni Composio** con una `COMPOSIO_API_KEY` reale e un account collegato.
6. Test batteria 12 h quando arriva l'hardware.

**Per me**, se vuoi: baseline Alembic che crea lo schema da zero (al posto di `schema.sql`), rate limiting per API key
invece che per IP, ed eventualmente traduzione delle entità estratte.
