# Echo — Stato del progetto (14/10/2026)

Analisi della codebase: cosa c'è, cosa funziona, cosa è rotto e cosa manca.
Prima analisi su `main` @ `5b235d0`; aggiornato dopo le correzioni del 13/10, le azioni Composio del
13–14/10 e la verifica completa sul nuovo PC del 14/10 (tutte e tre le suite eseguite, Composio provato
dal vivo). Tutto su `origin/main`.

---

## 1. Cos'è Echo

Wearable "second brain": un pendente ESP32-S3 ascolta, registra solo quando rileva voce, manda l'audio
al telefono via BLE; l'app lo inoltra a un backend self-hosted che trascrive, estrae entità
(persone, task, idee, eventi, note), costruisce una memoria vettoriale e risponde a domande in linguaggio naturale (RAG).
Su richiesta esplicita (chat o "Echo, …" a voce) agisce sulle app collegate tramite Composio.

```
XIAO ESP32-S3 Sense ──BLE (ADPCM, frame + CRC)──▶ App Flutter (iOS-first) ──HTTP──▶ FastAPI
  VAD + pre-buffer                                 relay, upload, UI                  │ Redis queues
  PSRAM ring buffer 512KB                                                             ▼
  mute persistente (NVS)                                                    Worker: STT → speaker → analisi
                                                                            → entità → chunk/embedding
                                                                            + richieste vocali "Echo, …"
                                                                            + riassunti, digest, retention
                                                          Azioni: agente → Composio (Gmail, Calendar, Slack…)
                                                                                      ▼
                                                                         PostgreSQL + pgvector
```

| Componente | Tecnologia | Test |
|---|---|---|
| `firmware/` | Arduino + NimBLE 2.3.2, PlatformIO | 8 suite Unity native, 79 test (protocollo, stato transfer, bond, mute, overflow, ring buffer) |
| `mobile/` | Flutter 3.44 (flutter_blue_plus, secure storage, local notifications) | 319 test (servizi + widget), `flutter analyze` pulito |
| `backend/` | FastAPI async, SQLAlchemy, Redis, OpenAI, Composio | 502 test pytest (unitari + integrazione con Postgres), ruff pulito |
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
- Onboarding a 4 step (server/API key → permessi → pairing → fine): server e chiave precompilabili in build
  (`--dart-define-from-file`), pairing saltabile e da fare dopo in Settings → Device.
- Tab Today / Memories / Tasks / Ask + Settings (Device, Connection, Privacy, Automations, Diagnostics, About).
- **Memories:** conversazioni per giorno (emoji, titolo, riassunto, persone, task, "Live"), ricerca sul server,
  dettaglio con Summary (task con la frase d'origine, eventi, idee) e Transcript correggibile.
- **Tasks:** task aperti per scadenza, completamento con Annulla, "Not a task", conversazione d'origine.
- **People** (in Memories): persone per ultima volta viste; la pagina di una persona ha ruolo e note, task ed
  eventi che la nominano, conversazioni in cui compare e "Ask about" (nuova chat con la domanda già inviata).
  Anche una conversazione ha "Ask about this conversation".
- **Today:** scheda del dispositivo (muto/riprendi, riconnetti o **Pair Echo**), **Needs you** con le azioni da
  confermare (anche quelle vocali), la giornata finora (conversazioni, minuti, persone), task in scadenza o creati
  oggi (con "Not a task"), l'ultimo riassunto giornaliero con il suo giorno.
- Relay BLE con riassemblaggio pacchetti, riconnessione automatica con backoff, restore state iOS (`bluetooth-central`).
- Policy di rete (Wi-Fi only opzionale), notifiche locali (disconnessione, perdita audio, upload falliti).
- Ask: risposte in streaming mentre vengono scritte, fonti con titolo e giorno della conversazione (aprono la
  conversazione), suggerimenti dalle conversazioni e persone recenti; "Add to calendar" dagli eventi passa
  dall'agente (conferma se ci sono invitati).
- Ask: chat con storico sessioni completo, feedback 👍/👎, input vocale, markdown; **schede Confirm/Cancel** per le
  azioni da confermare; conversazione **Voice requests** fissata in cima allo storico.
- Settings → Automations: **Integrations** (collega/scollega app tramite Composio, ricerca) e **Activity** (registro azioni).
- Notifiche delle risposte vocali al primo risveglio dell'app (upload di un segmento o ritorno in primo piano);
  il tocco apre la conversazione Voice requests.
- Tema chiaro/scuro, errori API tipizzati, logout.

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
- **Azioni via Composio** (`app/actions/`, [design](superpowers/specs/2026-10-13-composio-actions-design.md)):
  - Gmail, Google Calendar, Slack, Telegram (bot), Todoist, Notion + altre app cercabili; WhatsApp/Instagram personali no.
  - Agente OpenAI con tool calling e `search_memory`; dalla chat solo quando la richiesta riguarda un'app
    (pre-controllo a parole chiave + verifica dell'intento), dalla voce con "Echo, …" (anche "Eco", "Hey/Ehi Echo").
  - Lettura e creazione subito; invio ad altri, modifica, cancellazione e creazioni con invitati → azione in attesa
    da confermare (30 min, una volta sola). La scheda mostra tutti gli argomenti; strumenti sconosciuti = conferma.
  - Registro di ogni chiamata eseguita (anche quando la richiesta fallisce a metà); timeout → esito "sconosciuto".
  - Retry sicuri con `client_request_id`; messaggi espliciti se l'app non è collegata o Composio non risponde.
  - Sostituiscono le vecchie integrazioni automatiche, le regole e il client Google Calendar scritto a mano (rimossi).
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
| 3 | Progetti nativi iOS/Android ignorati da git | `a591b1e`, versionati il 14/10 in `e9f5ffd` |
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

### Risolti il 13–14/10/2026 nel lavoro sulle azioni Composio

Revisione per ogni task + revisione finale dell'intero lavoro e due giri successivi. Correzioni principali: richieste chat
oltre il timeout dell'app con retry che ripeteva l'azione; eventi con invitati creati senza conferma; scheda di conferma
che nascondeva destinatari (cc/bcc), testo e fuso orario; toolkit cercati mai usati; troppi strumenti offerti al modello;
risposte silenziose dalla memoria con Composio irraggiungibile; timeout riportati come "non fatto"; telemetria SDK
non davvero spenta; registro azioni perso quando una richiesta chat falliva. Dettagli e decisioni nel registro del
lavoro (`.superpowers/sdd/2026-10-13-composio-actions/`, fuori da git) e nei messaggi di commit.

### Risolti il 14/10/2026 (debito tecnico)

| Problema | Commit |
|---|---|
| Due verifiche d'intento in serie e richieste per un'app non collegata finite su un'altra app: ora una sola verifica (chat e voce) che dice quali app servono; app non collegata o non riconosciuta → "{App} non è collegata", nessuna app collegata → invito a collegarne una | `c941d1b` + fix |
| Database creato da `docs/schema.sql` + `stamp 001`: ora la migrazione 001 crea lo schema base e un'installazione nuova è solo `alembic upgrade head` (CI, `deploy.sh`, `make db-reset`, README); `schema.sql` resta come riferimento; 003 non più duplicata | `bbadc78` |
| Rate limit per IP (dietro Cloudflare Tunnel tutti condividevano lo stesso limite): ora per API key (hash), IP solo senza chiave | `2a83625` |
| Tentativi con API key sbagliata mai limitati: dopo 10 errori in 15 minuti lo stesso client riceve 429 (anche con la chiave giusta, così la risposta non rivela nulla); se Redis non risponde l'autenticazione continua a funzionare | vedi `git log` |

### Risolti il 14/10/2026 (verifica sul nuovo PC)

| Problema | Commit |
|---|---|
| `make test-all` girava sul DB di sviluppo e ne cancellava i dati dopo ogni test: ora i test rifiutano un DB che non finisce in `_test`, `make test-all` usa `echo_test` (creato e migrato da solo) nel container api | `ff887a9` |
| I test usavano le chiavi vere del `.env`: tre chiamavano OpenAI a ogni esecuzione e, con la chiave Composio valida, una query passava da Composio; ora valori finti come in CI e servizi simulati | `31b287e` |
| 13 test backend rotti (Redis mancante nel client di test, embedding finti con NaN, SQL non valido, oggetti scaduti letti dopo un rollback) | `1ee44e2` |
| "Connect" di un'app su Composio falliva con `TypeError` quando non esisteva ancora l'auth config (firma del wrapper SDK sbagliata) | `3bc3888` |
| 24 test Flutter rotti con Flutter 3.44; overflow a 320 pt con testo 1,3 in Today e onboarding; righe dei transcript lette due volte dagli screen reader | `e4b9a75`, `09538c6` |
| Progetti nativi `ios/`, `android/` e `pubspec.lock` non versionati; application id Android `com.example` | `e9f5ffd`, `450edd0` |
| 12 avvisi di `flutter analyze`; test firmware con la vecchia soglia VAD | `99c8b0b`, `c0de03f` |
| Server URL e API key da riscrivere a ogni installazione; pairing obbligatorio | `4a326d8`, `cf39a6e` |
| `make deploy` creava la chiave di esempio pubblica `my-secret-key`; porte 8000/5432/6379 aperte sulla LAN; codice morto e documentazione superata | vedi `git log` |

### Ancora aperti

- **`gpt-4o-transcribe` si spegne il 26/2/2027** (avviso OpenAI del 14/10/2026): da confrontare
  con Deepgram Nova-3 e `gpt-transcribe` (`make eval-stt`, servono registrazioni delle ultime 24 h).
  Analisi, chat, agente e instradamento sono già passati a `gpt-6-luna`
  ([MODEL-EVALUATION.md](MODEL-EVALUATION.md)).

- **La chiave di esempio `my-secret-key` è l'unica API key del DB di sviluppo**, esposto su internet dal tunnel:
  vedi §6, primo punto.
- **Speaker (#11):** la soglia è configurabile ma va calibrata su registrazioni reali.
- **Entità nella lingua parlata:** nomi e contenuti di task/eventi restano nella lingua della trascrizione
  (di solito italiano), quindi in Today possono comparire task in italiano dentro un'app in inglese. Scelta voluta
  (tradurre perderebbe fedeltà e confonderebbe la deduplicazione).
- **Composio provato solo in parte:** il collegamento di Google Calendar funziona; restano da provare una richiesta
  in chat e una a voce, le conferme, Telegram e Todoist, e i tempi reali di una richiesta.
- **`composio==0.22.0`:** dalla 0.24 dipende da `composio-client` 2.0 (release candidate), che si carica in ~50 s
  invece di ~20 s: da riprovare quando il client 2.0 sarà stabile. L'SDK si carica all'avvio di api e worker.
- **Instradamento:** dipende da una sola risposta del modello; 10/10 sui casi di `make eval-llm SUITE=routing`.
- **Minori:** se Redis non salva la risposta dopo il commit, i retry ricevono 409 per 10 minuti; schede e risposte
  possono essere lunghe con molti destinatari; il rilevamento della lingua per le risposte fisse è euristico
  (frasi brevi o miste cadono sull'inglese).

### Ambiente di sviluppo e CI
- Tutto gira in Docker: `make test-all`, `make test`, `make lint`, `make fmt` usano il container api (l'immagine
  installa le dipendenze dev). Guida: [DEVELOPMENT.md](DEVELOPMENT.md).
- La CI usa `echo_test` e chiavi finte; dopo le correzioni del 14/10 le tre suite passano in locale: l'esito della CI
  va controllato su GitHub Actions.
- Build Android non verificata su questo PC (manca l'SDK Android).

---

## 4. Cosa manca

### Rispetto alla spec Core Beta
| Requisito | Stato |
|---|---|
| Test continuo di 2 h su iPhone (foreground/background/locked) | ❌ da eseguire: [checklist](BETA-GATE-CHECKLIST.md) |
| Test batteria 12 h | ⏸ rimandato finché non arriva l'hardware |
| Today: task aperti + riassunto giornaliero | ✅ |
| Storico chat completo e riprendibile | ✅ |
| Rianalisi senza side effect | ✅ |
| Build iOS release riproducibile | ⚠️ progetti nativi versionati; build release da provare |
| Diagnostica del limite di consolidamento cross-conversazione | ❓ non trovata in UI |

### Dalla roadmap (ancora aperti)
- **Hardware reale:** calibrazione VAD (soglia fissa a 500, nessuna adattiva), misura consumi, range BLE.
- **Memoria:** diarization vera (oggi solo energia), riassunti settimanali, raggruppamento conversazioni per argomento.
- **Query:** filtri per persona ("cosa ha detto Marco?") e per tipo di entità nel RAG.
- **Firmware:** OTA, mute fisico (GPIO presente ma inutilizzato), lettura batteria (sempre 255), storage offline su microSD.
- **Provider alternativi:** solo OpenAI (LLM/embedding) e OpenAI/Deepgram (STT); niente modelli locali né Anthropic/Gemini.
- **Multi-utente / OAuth login:** fuori scope beta; l'API key si crea con `make create-key`.
- **Android in background:** non è un gate della beta.

---

## 5. Debito tecnico

- **Struttura del mobile:** `lib/services/` ha 30 file piatti (controller, adattatori, client API, BLE); andrebbe divisa
  per area (`ble/`, `api/`, `onboarding/`…) quando si tocca quella parte.
- **`backend/app/routers/query.py`** concentra RAG, instradamento verso le azioni e idempotenza: candidato a
  dividersi se cresce ancora.
- Fatto il 14/10: codice morto rimosso (`get_redis`, factory Deepgram inutilizzata, `embedding_dimensions`, gauge delle
  metriche, runner duplicato dei test speaker, riesportazione dell'onboarding), target `make` tutti nel container,
  porte solo su `127.0.0.1`, `make deploy` senza chiave di esempio, documentazione allineata.

---

## 6. Prossimi passi consigliati

**Per te:**

1. **Sostituire la chiave di esempio** (subito: il backend è pubblico): `make create-key`, mettere la chiave stampata
   in `mobile/dart_defines.json` e reinstallare l'app (o inserirla in Settings → Connection), poi
   `make revoke-example-key`.
2. **Controllare la CI** su GitHub Actions dopo il push.
3. **Provare le azioni Composio** dal vivo: una richiesta in chat ("che impegni ho domani?"), una che chiede conferma
   ("crea un evento con Marco"), una a voce ("Echo, …").
4. **Test di 2 ore della beta** con la [checklist](BETA-GATE-CHECKLIST.md).
5. **Calibrare** soglia VAD (`firmware/src/config.h`, oggi 500) e `SPEAKER_THRESHOLD_PERCENTILE` con registrazioni reali.
6. Test batteria 12 h quando arriva l'hardware.

**Per me**, se vuoi: Today senza dispositivo ("Pair Echo"), divisione di `mobile/lib/services/`, traduzione delle
entità estratte.
