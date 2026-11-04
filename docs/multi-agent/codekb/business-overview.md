# Business Overview — Echo

## Dominio e scopo

Echo è un "second brain" personale indossabile. Un wearable (ESP32-S3) registra il parlato con rilevamento dell'attività vocale, il telefono lo inoltra via BLE, e il backend lo trascrive, lo raggruppa in conversazioni, ne estrae conoscenza strutturata (persone, promesse, task, eventi, idee) e costruisce una memoria interrogabile in linguaggio naturale. Su richiesta esplicita, Echo agisce sulle altre app dell'utente (email, calendario, chat, task, note) e su Promemoria/Calendario del telefono.

Fase attuale (README, `docs/PROJECT-STATUS.md`): **core beta** — iPhone, wearable e un backend gestito da Echo, con account email separati per utente. Licenza proprietaria.

Glossario di dominio (`CONTEXT.md`): **Wearable**, **VAD**, **Segment** (unità minima di audio), **Mute**, **Transcription**, **Conversation** (gruppo di Segment), **Analysis** (estrazione LLM asincrona), **Entity**, **Memory**, **Query**, **Recall** (pipeline RAG).

## Funzionalità chiave

| Area | Cosa fa | Dove vive nel codice |
|---|---|---|
| Ricordare | Ingest audio → STT → speaker → conversazioni → entità → chunk/embedding → riassunti e digest | `backend/app/routers/segments.py`, `backend/app/workers/stt.py`, `workers/analysis.py`, `services/analysis_pipeline.py`, `workers/summaries.py`, `workers/digest.py` |
| Rispondere | Chat (anche in streaming SSE) con RAG sulla memoria, ricerca web per informazioni live | `backend/app/routers/query.py`, `services/memory_retrieval.py`, `services/memory_answers.py`, `services/web_search.py` |
| Agire | Agente tool-calling su Composio (Gmail, Calendar, Slack, Telegram, Todoist, Notion…), Promemoria/Calendario del telefono, WhatsApp in sola lettura; conferma obbligatoria per invii/modifiche/cancellazioni | `backend/app/actions/` |
| Richieste vocali | "Ehi Echo, …" rilevato dopo la trascrizione, confermato dal modello, instradato come la chat | `backend/app/actions/voice.py`, `workers/voice_requests.py` |
| Routine | Attività pianificate (giornaliere, feriali, settimanali, mensili) eseguite dal server tramite l'agente, senza strumenti che richiedono conferma | `actions/routine_tools.py`, `workers/routines.py`, `services/routine_results.py` |
| Assistants | Echo focalizzato su un ambito (lavoro, dieta, sonno o personalizzato) con istruzioni, note proprie e documenti scelti | `services/assistants.py`, `actions/assistant_tools.py`, `models/assistant.py` |
| Saved, About you, Documenti | Cose da ritrovare (con luogo/foto), fatti stabili sull'utente, documenti PDF/Word/testo indicizzati | `services/saved.py`, `services/user_facts.py`, `services/documents.py`, `workers/documents.py` |
| Foto su richiesta | Il wearable scatta una foto, un modello vision risponde e la descrive per la memoria | `services/photos.py`, `workers/photos.py` |
| Chi parla | Impronte vocali ONNX locali e regola di energia | `services/voice_embedding.py`, `services/voice_profiles.py`, `services/speaker_detector.py` |
| Notifiche | Al massimo 3 al giorno: promesse, briefing prima di un incontro, briefing quando parla una voce nota | `services/notifications.py`, `services/person_brief.py` |
| App esterne via MCP | Claude, Cursor ecc. leggono la memoria con una chiave `read` | `backend/app/mcp/` |
| Piani e costi | Piani free/plus/unlimited (minuti di parlato, ricerche web, routine), consumo per utente e giorno | `services/plans.py`, `services/usage.py`, `services/usage_report.py` |
| Aggiornamenti firmware | OTA firmata via BLE attraverso l'app | `services/firmware.py`, `routers/firmware.py`, `firmware/src/ota_*.h` |

## Attori

- **Utente** (titolare dell'account): indossa il wearable, usa l'app, conferma le azioni.
- **Persone intorno all'utente**: la loro voce è registrata e trascritta; il loro testo è trattato come dato non fidato dall'agente.
- **Operatore del server**: gestisce account (`make create-user`, `make set-plan`), dead letter queue (`X-Admin-Token`), rilascio firmware, deploy.
- **App collegate (MCP)**: assistenti esterni con chiave di sola lettura.
- **Servizi terzi**: OpenAI, Deepgram, Composio, WhatsApp (non ufficiale), Cloudflare Tunnel.

## Vincoli di business rilevanti per l'intent

- **Le azioni avvengono solo quando richieste**: "Nothing happens from speech that is not addressed to Echo" (README). Lettura e creazione immediate; invio ad altri, modifica, cancellazione attendono un **Confirm** (pending action, 30 minuti). Strumenti sconosciuti → conferma.
- **Privacy**: Composio riceve solo gli argomenti dei tool; il log di audit oscura i corpi; MCP non vede documenti né luoghi; WhatsApp mai su disco.
- **Costo per utente misurabile**: ogni chiamata a modelli registrata per utente/giorno/kind/model (`llm_usage`); piani con quote (minuti di STT, ricerche web al giorno, numero di routine).
- **Roadmap "Fase 7 — un agente per utente"** (`docs/ROADMAP.md`): già decisi un solo motore (l'agente delle azioni in Python) con profilo per utente nel DB; aperti: esecuzioni durevoli, Echo come client MCP, chat come agente con la memoria come strumento, quote per agente, regole a evento. "Le conferme restano regole nel codice, mai una probabilità di un modello".
