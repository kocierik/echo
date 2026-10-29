# Echo — Stato del progetto (28/10/2026)

Analisi della codebase: cosa c'è, cosa funziona, cosa è rotto e cosa manca.
Prima analisi su `main` @ `5b235d0`; aggiornato dopo le correzioni del 13/10, le azioni Composio del
13–14/10 e la verifica completa sul nuovo PC del 14/10 (tutte e tre le suite eseguite, Composio provato
dal vivo). Aggiornato il 16/10 dopo la nuova interfaccia, il primo avvio con account e registrazione,
l'aggiornamento del firmware via Bluetooth e Promemoria/Calendario dell'iPhone. Aggiornato il 22/10 dopo la
ricerca web, gli incarichi ricorrenti, le nuove schede Today · Ask · Profile, i to-do solo su richiesta e le
promesse più rigide. Aggiornato il 28/10 dopo gli incarichi che parlano solo quando serve. Il dettaglio di
quanto resta è in [ROADMAP.md](ROADMAP.md).

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
| `firmware/` | Arduino + NimBLE 2.3.2, PlatformIO | 12 suite Unity native, 109 test (protocollo, transfer, bond, mute, pulsante, OTA, buffer, foto) |
| `mobile/` | Flutter 3.44 (flutter_blue_plus, secure storage, local notifications) | 581 test (servizi + widget, ~4 min), `flutter analyze` pulito |
| `backend/` | FastAPI async, SQLAlchemy, Redis, OpenAI, Composio, Argon2, MCP SDK 1.30 | 735 test pytest (~2 min), ruff pulito |
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
- **Fotocamera** (protocollo 3, [ADR 0007](adr/0007-camera-photos-on-request.md)): `TAKE_PHOTO` dall'app, foto JPEG
  (XGA) scattata in un task sul core 0 con il sensore acceso solo per lo scatto, tenuta in RAM fino a `UPLOAD_OK` e
  inviata prima dell'audio; `PHOTO_FAILED` se in muto, occupato, senza fotocamera o se lo scatto fallisce; LED acceso
  durante lo scatto. Provato sull'hardware il 24/10 con Echo (scatto, invio via Bluetooth, risposta in chat).
- **Pulsante fisico** (D1/GPIO2): pressione breve = foto, lunga = muto/riattiva.
- **Aggiornamento via Bluetooth** (protocollo 4, [ADR 0009](adr/0009-firmware-updates-over-ble.md)): l'app scarica
  la versione dal server, la invia a pezzi verificando lo SHA-256; il dispositivo torna alla versione precedente se
  la nuova non si collega all'app entro 5 minuti. Firmware attuale 0.6.0.
- **microSD** (24/10, 0.6.0): quando la PSRAM è piena i segmenti più vecchi passano su file da 4 MB nella scheda
  (SPI, CS GPIO21: il LED non si usa più), con la posizione di lettura salvata e i record tagliati o con CRC
  sbagliato saltati; il telefono riceve prima quelli della scheda. Senza scheda come prima. Non cifrati.

### App mobile
- **Primo avvio** ([design](superpowers/specs/2026-10-16-first-run-and-sign-in-design.md)): schermata di avvio nei
  colori di Echo (chiara e scura), benvenuto animato, accesso con email e password o **creazione dell'account**,
  permessi, abbinamento (rimandabile), privacy, primo risultato con un comando vocale. Il server è fisso nell'app;
  Apple e Google sono mostrati come "in arrivo".
- **Account:** ogni telefono riceve una chiave sua (nel Keychain/Keystore); Settings → Devices elenca telefoni e
  chiavi per gli script, con Sign out e Revoke; una chiave revocata altrove fa uscire il telefono una volta sola e
  lo dice sul benvenuto.
- Tre schede **Today | Ask | Profile** (22/10, [design](superpowers/specs/2026-10-22-app-tabs-redesign-design.md))
  con il pulsante Ask rotondo al centro (tenuto premuto detta la domanda) e la **pillola del dispositivo** (tocco =
  schermata Echo: stato, batteria, muto, riconnessione, firmware, Forget device; pressione lunga = muto). Tasks è una
  pagina di Today. **Profile:** nome, email e lingua; la scheda Echo; "Echo does" (Apps, Routines, On this iPhone,
  Notifications, Activity), "You" (Voices, Language, Privacy, Appearance), What Echo can do, e Devices, server,
  diagnostica, About.
- Interfaccia "A + C": pannelli su un fondo quieto, font Archivo; tema "System" di default, scuro quasi nero.
- **Conversazioni** (in Today, dove è finito Memories): per giorno (emoji, titolo, riassunto, persone, "Live"),
  ricerca sul server, dettaglio con Summary (promesse con la frase d'origine, eventi, idee) e Transcript correggibile.
- **Tasks:** task aperti per scadenza, completamento con Annulla, "Not a task", conversazione d'origine.
- **People** (in Memories): persone per ultima volta viste; la pagina di una persona ha ruolo e note, task ed
  eventi che la nominano, conversazioni in cui compare e "Ask about" (nuova chat con la domanda già inviata).
  Anche una conversazione ha "Ask about this conversation".
- **Today, a modo tuo** (28/10, [design](superpowers/specs/2026-10-28-today-your-way-design.md)): il dispositivo solo
  se c'è un problema, in cima solo le **azioni da confermare** ("+N more"), poi le sezioni nell'ordine scelto
  dall'utente: From your routines, **To do today**, **Coming up today** (gli appuntamenti di oggi ancora da venire dal
  calendario dell'iPhone, con "Last time: …" sotto quello entro l'ora), **Your day** (conversazioni e foto; la
  conversazione in corso con durata, persone, titolo e ultima frase), People, Saved, **Where you've been** (i luoghi
  di oggi se Places visited è acceso; un tocco apre la mappa) ed **Earlier days**. "Edit Today" in fondo nasconde e
  sposta le sezioni (salvato sul telefono); la ricerca in tutta la memoria è un'icona in alto. "Echo is working
  on…" è in Ask, in fondo al thread.
- **Spoken answers** (28/10, Profile): il telefono legge ad alta voce le risposte alle richieste a voce, anche a
  schermo bloccato (`flutter_tts`, modalità audio in background su iOS). Off / solo in cuffia / sempre; Echo va in
  muto mentre il telefono parla (anche in cuffia: un'auto o una cassa Bluetooth sembrano cuffie) e torna ad
  ascoltare dopo (se l'app muore a metà, lo rimette in ascolto alla riconnessione). Testo senza markdown né link,
  tagliato a ~500 caratteri ("Il resto è in Ask."); tenere premuto Ask ferma la voce, e mentre detti non parla.
- **Altre lingue e traduzione** (28/10, Profile → Language): fino a 4 lingue sentite intorno (en, it, es, fr, de,
  pt). Con almeno una, la trascrizione riconosce in quale lingua è ogni segmento (Deepgram `detect_language`
  ristretto a quelle; se rifiuta le keyterm insieme, riprova senza) e la salva; senza, nulla cambia. Nella
  conversazione le righe in un'altra lingua hanno l'etichetta "EN" e "Translate to Italiano" mostra la traduzione
  sotto l'originale (LLM, una volta per riga, salvata; una riga corretta si ritraduce).
- **Memoria** (29/10, Profile → Memory): **About you**, frasi su di te (60 al massimo) in ogni risposta; Echo ne
  propone fino a 3 per conversazione dalle tue parole (righe [You], dopo il riassunto), mai su salute, politica,
  religione, sessualità, etnia, debiti, e le usa solo se le tieni; "ricordati che…"/"dimentica che…" le aggiungono
  o tolgono a voce (tenuti solo se il tuo messaggio lo chiede; altrimenti restano suggerimenti). **Documents**:
  PDF, Word, testo, Markdown (10 MB, 30 al massimo); il worker legge il file in un thread, con limiti (pagine,
  dimensione aperta, lunghezza del testo), lo butta appena letto e tiene solo il testo, diviso e indicizzato; uno
  illeggibile (PDF scansionato, password, file binario, zip enorme) finisce "failed" con il motivo. Le risposte di
  memoria usano i 3 passaggi più vicini (similarità ≥ 0,35), nominando il documento; le app collegate via MCP non
  vedono i documenti. Fatti e documenti sono nell'export.
- **Assistenti** (29/10, Profile → Assistants; idee da Khoj agents, Letta e le prompt app di Omi): Echo dedicato a
  una parte della vita, da modello (Lavoro, Dieta, Sonno; dieta e sonno dicono di non essere un medico) o da zero:
  nome, emoji, istruzioni (2.000 caratteri), note (3.000) che l'assistente aggiorna da solo con uno strumento
  (aggiunge o toglie una riga; piene, si buttano le più vecchie), documenti scelti (nessuno: tutti); 10 al massimo.
  In Ask una nuova chat parte con un assistente (chip Echo e uno per assistente); la sua chat passa sempre
  dall'agente con le sue istruzioni e note dopo quelle dell'utente, ricorda l'assistente anche riaperta, e la
  cronologia mostra emoji e nome. Gli incarichi creati nella sua chat girano come lui. Cancellarlo lascia chat e
  incarichi a Echo.
- **WhatsApp in lettura** (29/10, Profile → WhatsApp): un servizio Node (`whatsapp/`, Baileys 7) collega il numero
  dell'utente come dispositivo con un codice di abbinamento; mai online, non invia e non segna come letto. Tiene
  le chat private (entrambi i lati, niente gruppi) solo in RAM, 7 giorni e 20.000 messaggi al massimo; le chiavi
  della sessione nel volume `whatsapp_data`. L'agente ha `WHATSAPP_LIST_CHATS` e `WHATSAPP_READ_CHAT` in Ask, nelle
  richieste a voce e nelle routine, solo mentre è collegato. Non ufficiale: WhatsApp può bloccare il numero.
  Acceso di default nel compose (token predefinito finché non se ne mette uno nel `.env`; URL vuoto lo spegne).
- Relay BLE con riassemblaggio pacchetti, riconnessione automatica con backoff, restore state iOS (`bluetooth-central`).
- Policy di rete (Wi-Fi only opzionale), notifiche locali (disconnessione, perdita audio, upload falliti).
- Ask: risposte in streaming mentre vengono scritte, fonti con titolo e giorno della conversazione (aprono la
  conversazione), suggerimenti dalle conversazioni e persone recenti; "Add to calendar" dagli eventi passa
  dall'agente (conferma se ci sono invitati).
- Ask: **un unico thread con Echo** (22/10): domande scritte, richieste a voce ("By voice · 08:02"), foto con la
  risposta e le azioni rapide (Translate it, Ask more, Remind me quando la foto mostra una data), i risultati
  degli incarichi solo quando l'utente li porta con "Ask about this"; New chat apre una chat a parte; fonti web
  cliccabili; storico completo, input vocale, markdown, **schede Confirm/Cancel**.
- **Ask → Routines** (28/10): in cima ad Ask un selettore Chat | Routines; i risultati degli incarichi per giorno,
  con il testo intero e le fonti, filtrabili per incarico; i controlli senza novità in una riga grigia.
- **Today → From your routines** (28/10): i risultati di oggi sopra "To do today"; un tocco apre il testo intero.
- **Profile → Routines:** gli incarichi con orario, modo ("Tells you only if…"), prossima esecuzione e ultimo
  risultato (si apre intero), "See all results"; pausa e cancellazione.
- Settings → Automations: **Integrations** (collega/scollega app tramite Composio, ricerca) e **Activity** (registro azioni).
- Notifiche delle risposte vocali al primo risveglio dell'app (upload di un segmento o ritorno in primo piano) e,
  per gli incarichi, quando arriva il comando `voice_update`; il tocco apre il thread in Ask.
- **Chi hai davanti** (24/10): quando una voce nominata parla (soglia sicura, mai la tua), il server manda il comando
  `person_brief` con quello che c'è da sapere (promesse nei due sensi, ultima conversazione), mostrato subito come
  notifica che apre la persona; al massimo una volta ogni 4 ore per persona, mai entro un'ora da un briefing di
  calendario su di lei, sotto l'interruttore dei briefing, ore di silenzio e tre al giorno in totale (registro in
  Redis, `services/notice_ledger.py`); nessuna chiamata al modello.
- **Foto:** pulsante 📷 in Ask (il testo scritto diventa la domanda), risposta nella chat con la miniatura (tocco =
  schermo intero); i comandi "Echo, cos'è questo?" arrivano con un long poll e vengono inoltrati al dispositivo; le
  foto si caricano anche con "solo Wi-Fi". Protocollo 2 e 3 accettati.
- Tema chiaro/scuro, errori API tipizzati, logout.

### Backend
- **Ricerca web** (22/10, `services/web_search.py`): lo strumento di OpenAI offerto a chat, voce, agente e incarichi
  finché l'utente è sotto `WEB_SEARCHES_PER_DAY` (30); ogni ricerca contata in `llm_usage` (0,010 $, da verificare);
  le pagine citate nella risposta (`web_sources`), mai nella memoria. Il meteo arriva da una fonte di OpenAI senza
  pagina da citare; una ricerca di notizie può impiegare ~12 s.
- **Incarichi ricorrenti** (22/10, `workers/routines.py`): creati dall'agente con i suoi strumenti (anche senza app
  collegate), eseguiti ogni minuto con `FOR UPDATE SKIP LOCKED`, senza strumenti da confermare, ora locale anche
  col cambio dell'ora; se il server era giù da più di 2 h l'esecuzione è saltata. Migrazione 020. Dal 28/10
  (migrazione 026) ogni esecuzione è una riga di `routine_runs` (90 giorni) e ogni incarico ha un modo: `always`,
  `only_if` (risposta JSON, parla solo se vale la condizione) e `only_new` (il server scarta quanto già
  riferito, riconoscendo lo stesso link anche con parametri diversi); una risposta illeggibile è convertita una
  volta, poi riferita com'è. Il telefono è avvisato solo per risultati ed errori.
- **To-do e promesse** (22/10): dalle conversazioni nascono solo le promesse esplicite dell'utente; gli altri to-do
  li chiede l'utente ("Ehi Echo, segnami…"): nella lista di Echo, nell'app che nomina o nei Promemoria per un'ora.
- **Account** (`routers/auth.py`): `POST /api/auth/login` e `/register` danno una chiave per telefono (solo l'hash
  nel DB), `logout`, `devices`, revoca; password Argon2 controllate fuori dal loop; tentativi falliti contati prima
  del controllo, per indirizzo e per email (10 in 15 minuti); al massimo 5 registrazioni l'ora per indirizzo;
  `REGISTRATION_OPEN=false` chiude la registrazione; `make create-user` / `make set-password` dal server.
- **Costi** (`app/services/usage.py`): ogni chiamata a pagamento (trascrizione, embedding, i quattro ruoli
  dei modelli) è contata per utente e giorno in `llm_usage`; `make usage` stampa il costo di un giorno, per
  tipo di lavoro, e il costo di un'ora di parlato. I prezzi (`app/usage_prices.py`) sono da verificare.
- **App collegate e MCP** (`app/mcp/`): chiavi `read` per Claude, Cursor e simili, solo su `/mcp`; sei
  strumenti di sola lettura sulle memorie; la REST rifiuta quelle chiavi (403).
- **Domande su Echo e fuori tema**: le istruzioni del modello sanno cosa sa fare Echo; domande generali con
  risposta breve "non dalla memoria", nessuna invenzione sul passato né su informazioni in tempo reale.
- **La lingua che parli**: una per account (inglese o italiano), per la trascrizione e la dettatura.
- **Promemoria e Calendario dell'iPhone** ([ADR 0010](adr/0010-iphone-reminders-and-calendar.md)): l'agente li usa
  tramite comandi all'app (EventKit), senza Composio.
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
- **Foto:** l'intento vocale ha l'opzione fotocamera; richieste in `photos`, comandi al dispositivo in Redis
  (`GET /api/device/commands`, long poll), JPEG nel DB, worker che chiede al modello visivo (`gpt-6-luna`) la
  risposta per la chat e la descrizione per la memoria (chunk con `photo_id`, mantenuto dalla rianalisi); richieste
  senza risposta falliscono dopo 90 s con un messaggio. La sessione vocale è bloccata mentre viene riscritta.
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

- **Trascrizione:** questo server usa Deepgram Nova-3 (`STT_PROVIDER=deepgram`), non toccato dalle
  deprecazioni OpenAI. Solo con `STT_PROVIDER=openai` conta lo spegnimento di `gpt-4o-transcribe` (26/2/2027,
  sostituto `gpt-transcribe`); il confronto (`make eval-stt`) resta utile per scegliere il migliore, non urgente.
  Analisi, chat, agente e instradamento sono già passati a `gpt-6-luna` ([MODEL-EVALUATION.md](MODEL-EVALUATION.md)).

- **La chiave di esempio `my-secret-key` è l'unica API key del DB di sviluppo**, esposto su internet dal tunnel:
  vedi §6, primo punto.
- **Speaker (#11):** con il profilo vocale registrato decidono le impronte; senza, la soglia di energia (da calibrare).
- **Entità nella lingua parlata:** nomi e contenuti di task/eventi restano nella lingua della trascrizione
  (di solito italiano), quindi in Today possono comparire task in italiano dentro un'app in inglese. Scelta voluta
  (tradurre perderebbe fedeltà e confonderebbe la deduplicazione).
- **Da applicare sul server** (`make deploy`): migrazioni 016–019 (lingua, consumi, permessi delle chiavi,
  chiamate MCP) e l'immagine con l'SDK MCP. Prima di allora `make usage` e `/mcp` non funzionano lì.
- **MCP solo con chiave:** claude.ai e ChatGPT vogliono OAuth, da fare; Claude Desktop non è verificato.
- **Account appena fatti:** registrazione e accesso sono provati solo dai test. Sul server serve `make deploy`
  e il proprio account (`make create-user`). Mancano conferma dell'email, recupero password via email, Apple e
  Google. Con la registrazione aperta chiunque trovi il server può crearsi un account e usare la chiave OpenAI del
  server: `REGISTRATION_OPEN=false` la chiude.
- **Android mai compilato:** su questo Mac manca l'SDK. Non verificati: schermata di avvio Android 12+, canale
  `echo/device` in `MainActivity.kt`, tutto il resto dell'app. Promemoria/Calendario e Live Activity sono solo iOS.
- **Nuova interfaccia vista solo nei test:** da guardare sul telefono (spaziature, tema quasi nero).
- **Il server gira sul Mac:** se è spento o senza rete, Echo non funziona; i backup sono a mano.
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
- Build Android non verificata su questo PC (manca l'SDK Android): vedi sopra.

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
- **Memoria:** raggruppamento conversazioni per argomento. Impronte vocali fatte ([ADR 0008](adr/0008-voice-fingerprints.md)):
  soglie da calibrare su registrazioni reali; un segmento con più voci prende quella prevalente.
- **Query:** filtro per tipo di entità nel RAG (la ricerca per persona c'è: prima le conversazioni in cui compare).
- **Firmware:** la lettura della batteria
  c'è (A0, partitore 1:2) ma va attivata con `BATTERY_DIVIDER_FITTED 1` dopo aver montato le resistenze.
- **Provider alternativi:** solo OpenAI (LLM/embedding) e OpenAI/Deepgram (STT); niente modelli locali né Anthropic/Gemini.
- **Multi-utente:** account, registrazione e dati separati ci sono; mancano quote/costi per utente, conferma
  dell'email, recupero password, Apple/Google, più dispositivi Echo per account.
- **Android in background:** non è un gate della beta.

---

## 5. Debito tecnico

- **Struttura del mobile:** fatto il 15/10: `lib/services/` è divisa per area (`api/`, `app/`, `chat/`, `device/`,
  `memory/`, `onboarding/`), i test seguono la stessa struttura.
- **`backend/app/routers/query.py`:** alleggerito il 15/10 (storico chat in `services/chat_history.py`, prompt e
  testi delle risposte in `services/memory_answers.py`); restano endpoint, idempotenza e instradamento.
- Fatto il 14/10: codice morto rimosso (`get_redis`, factory Deepgram inutilizzata, `embedding_dimensions`, gauge delle
  metriche, runner duplicato dei test speaker, riesportazione dell'onboarding), target `make` tutti nel container,
  porte solo su `127.0.0.1`, `make deploy` senza chiave di esempio, documentazione allineata.

---

## 6. Prossimi passi consigliati

**Per te:**

1. **`make deploy`** e riavvio dell'API: installa `argon2-cffi` e applica le migrazioni (la 015 è già applicata).
2. **Il tuo account:** `make create-user EMAIL=…` (si aggancia ai dati che hai), poi nell'app esci e rientra per
   avere una chiave tua; **`make revoke-example-key`** per la chiave pubblica `my-secret-key`; togli `ECHO_API_KEY`
   da `mobile/dart_defines.json`.
3. **Firmware 0.6.0 via cavo**, reinstallare l'app, registrare la voce, provare Promemoria e Calendario.
4. **Guardare la nuova interfaccia sul telefono** e dire cosa cambiare (anche il tema quasi nero).
5. **Decidere sulla registrazione aperta**: lasciarla (lo hai scelto) o chiuderla con `REGISTRATION_OPEN=false`.
6. **Provare le azioni Composio** dal vivo: una richiesta in chat, una che chiede conferma, una a voce.
7. **Test di 2 ore della beta** con la [checklist](BETA-GATE-CHECKLIST.md); test batteria di 12 ore.
8. **Calibrare** soglia VAD (`firmware/src/config.h`, oggi 500) e `SPEAKER_THRESHOLD_PERCENTILE` con registrazioni reali.
9. **Provare la fotocamera** (OV3660): monitor seriale `[Camera] sensor PID`, tempo e peso della foto, poi 📷 in
   Ask e "Echo, cos'è questo?"; misurare consumo e calore.
10. **Android:** installare l'SDK (o una CI) e provare la build.
11. Più avanti: spostare il server su un VPS in Europa con backup notturni; account sviluppatore Apple per
    "Accedi con Apple" e la pubblicazione.

**Per me**, se vuoi: equivalenti Android di Promemoria/Calendario, il deploy su VPS (Compose di produzione,
backup), recupero password via email quando ci sarà un servizio di invio, traduzione delle entità estratte.
