# Echo — Roadmap

> Aggiornata al 16/10/2026. Stato dettagliato, bug noti e prossimi passi: [PROJECT-STATUS.md](PROJECT-STATUS.md).
> Il piano nasce dal confronto con i concorrenti (Omi, Bee, Plaud, Limitless, occhiali con fotocamera) del
> 15/10/2026: prima non perdere niente, poi sfruttare ciò che solo Echo ha (fotocamera, voci, server tuo),
> poi far arrivare Echo da te e rendere l'app immediata.

## Piano

Ogni fase si progetta e si costruisce a sé; l'ordine è concordato.

### Fase 0 — Prerequisiti (utente)
- [ ] `make deploy` (installa `argon2-cffi`, applica le migrazioni) e riavvio dell'API
- [ ] Il proprio account: `make create-user EMAIL=…` (si aggancia ai dati già registrati), poi accedere dall'app
      (Settings → Devices mostra i telefoni collegati)
- [ ] Revocare la chiave di esempio pubblica (`make revoke-example-key`) e togliere `ECHO_API_KEY` da
      `mobile/dart_defines.json` (non è più usata)
- [ ] Caricare il firmware 0.5.0 via cavo (l'ultima volta: i successivi arrivano via Bluetooth), reinstallare
      l'app, registrare la propria voce (Settings → Voices), provare Promemoria e Calendario
- [ ] Una giornata d'uso vero: i dati servono per misure e tarature della Fase 1

### Fase 1 — Non perdere niente (firmware)
- [x] Buffer offline da ~64 s a ~13 minuti di parlato, con la PSRAM libera (8 MB); in Today "N min of speech to sync"
- [x] Pulsante fisico (D1/GPIO2 → GND): pressione breve = foto con notifica, lunga = muto/riattiva
- [ ] Tarature sui dati reali: tempi dei comandi vocali (scatto anticipato se serve), soglie delle voci,
      risoluzione delle foto

### Fase 2 — Fotocamera più utile
- [x] Le foto generano task ed eventi (estrazione delle entità sulla descrizione)
- [x] Foto nel dettaglio della conversazione (riepilogo e transcript) e in Memories (📷 N)
- [x] Biglietto da visita → persona in People con ruolo, azienda, email, telefono (contatto Google: a richiesta in chat)

### Fase 3 — Echo viene da te
- [x] Riepilogo serale (spento di default, attivabile in Settings → Notifications)
- [x] Promesse da mantenere: riconosciute nell'estrazione, sezione "Promises" in Today, notifica la mattina
      della scadenza
- [x] Briefing 10 minuti prima di un incontro, solo se c'è qualcosa da sapere sulla persona (apre la sua pagina)
- Deciso: notifiche programmate dal telefono a ogni risveglio (niente account sviluppatore a pagamento); al
  massimo 3 al giorno, mai tra le 22 e le 8

### Fase 4 — Esperienza d'uso
- [x] App veloce anche offline: copia locale delle letture (cancellata al logout), Today si apre dalla copia,
      striscia "Offline · updated 14:32"
- [x] "Echo sta lavorando…" per i comandi vocali e le foto in arrivo, finché arriva la risposta (dal 28/10 in Ask,
      in fondo al thread)
- [x] Today a modo tuo (28/10, [design](superpowers/specs/2026-10-28-today-your-way-design.md)): le sezioni
      nell'ordine dell'utente, nascondibili ("Edit Today"); l'agenda di oggi; i luoghi visitati in Today; la ricerca
      da un'icona; in cima solo le azioni da confermare
- [x] Risposte a voce dal telefono (28/10, [design](superpowers/specs/2026-10-28-spoken-answers-design.md)):
      sintesi vocale del telefono, solo in cuffia o anche sull'altoparlante, anche ad app in background
- [x] Traduzione delle trascrizioni (28/10, [design](superpowers/specs/2026-10-28-transcript-translation-design.md)):
      le altre lingue sentite, riconosciute nella trascrizione; le righe in un'altra lingua tradotte nell'app
- [x] Far scoprire le funzioni: pagina "What Echo can do" con esempi da toccare, suggerimenti una volta sola
      (registra la tua voce, nomina chi parla), riga "Hold 🎙 to talk · 📷" in Ask
- [x] Live Activity (iOS 16.1+): schermata di blocco e Dynamic Island con stato (ascolta/muto/offline),
      batteria e minuti in attesa di sync; aggiornata dall'app, senza push. Spegnibile in Settings → Notifications
- [x] Condividere una conversazione (testo/Markdown); export di tutti i dati in JSON (Settings → Privacy)

### Fase 5 — App nuova e primo avvio (16/10)
- [x] Nuova interfaccia "A + C": pannelli su un fondo quieto, font Archivo; tre schede Today | Ask | Memories con
      il pulsante Ask rotondo al centro (tenuto premuto detta la domanda); la pillola del dispositivo in ogni
      intestazione (tocco = Settings, pressione lunga = muto); Tasks diventa una pagina di Today
- [x] Today in pannelli (Needs you, To do today, Your day sulla linea del tempo, Echo can act in), Ask con
      risposte in pannelli e fonti visibili, Memories con settimana, ieri, persone e giorni in pannelli,
      Settings con il dispositivo disegnato in alto; anche le pagine di dettaglio e l'onboarding
- [x] Tema scuro quasi nero (`#0E0F10`), tema "System" di default
- [x] Primo avvio: schermata di avvio nei colori di Echo, benvenuto animato (il dispositivo "cattura" le parole),
      accesso con email e password, permessi, abbinamento, privacy e un primo risultato con un comando vocale
      ([design](superpowers/specs/2026-10-16-first-run-and-sign-in-design.md))
- [x] Account: ogni telefono ha la sua chiave (revocabile da Settings → Devices), password Argon2, tentativi
      limitati; registrazione dall'app (chiudibile con `REGISTRATION_OPEN=false`); niente più server e chiave da
      inserire a mano
- [ ] Accedi con Apple e Google: i pulsanti ci sono ("in arrivo"); servono l'account sviluppatore Apple a
      pagamento e un client OAuth Google

### Fase 6 — Piattaforma
- [x] Aggiornamento del firmware senza cavo: `make firmware-release` → server → app → Bluetooth, con
      controllo SHA-256 e ritorno automatico alla versione precedente ([ADR 0009](adr/0009-firmware-updates-over-ble.md))
- [ ] microSD (solo se il buffer attuale risulta corto nell'uso reale)
- [x] Promemoria e Calendario dell'iPhone (senza Composio): Echo crea e legge promemoria ed eventi,
      e i promemoria prima delle riunioni usano anche il calendario dell'iPhone
      ([ADR 0010](adr/0010-iphone-reminders-and-calendar.md))
- [ ] Test di 2 ore della core beta su iPhone ([checklist](BETA-GATE-CHECKLIST.md)) e test batteria di 12 ore
- [x] Android: servizio in primo piano con notifica di stato, calendario del telefono, testi "phone";
      `flutter build apk --debug` passa (16/10)
- [ ] Android: provare su un telefono con il dispositivo (Bluetooth in background, calendario)

### Fase 7 — Echo fuori da Echo: MCP e un agente per utente (in discussione)
Prerequisiti, prima di dare memorie e azioni a sistemi esterni o di far agire Echo da solo:
- [x] Chiavi con permessi (16/10): `full` per telefoni e script, `read` per le app collegate (solo MCP; la
      REST risponde 403)
- [x] Consumo per utente (16/10): token e secondi di audio di ogni chiamata, per utente e giorno
      (`llm_usage`); `make usage` dà il costo di un giorno e di un'ora di parlato. Prezzi in
      `backend/app/usage_prices.py`, da verificare sulle pagine ufficiali
- [ ] Quote mensili per utente (dopo i prezzi)
- [ ] Prezzi (da fissare dopo la misura dei costi): come Omi e Plaud, a minuti al mese in tre fasce (gratis
      ~300 min, intermedia, Unlimited ~30 $/mese); finito il budget si rallenta senza perdere nulla, come Omi
      (deciso il 16/10): l'audio si salva sempre, l'elaborazione aspetta (o va in differita) fino al mese dopo
      o a una ricarica. Più avanti un gateway (LiteLLM) con una chiave virtuale e un
      budget per utente. Trascrizione sul telefono (come il piano gratis di Omi): rimandata
- [ ] Costi più bassi (deciso il 16/10: prima misurare quanto costa un giorno di Echo, voce per voce): il lavoro
      non urgente (estrazione, riassunti, digest) con l'API Batch a metà prezzo; la chat sugli abbonamenti degli
      utenti (MCP per Claude e ChatGPT; "Sign in with ChatGPT" per Ask se OpenAI accetta Echo, modulo di
      interesse per i prodotti ospitati); trascrizione in proprio se è la voce più cara. Gli abbonamenti Claude
      non si possono usare fuori dalle app di Anthropic

MCP — le memorie di Echo dentro Claude, ChatGPT e altri assistenti:
- [x] Server MCP remoto (16/10; `/mcp`, Streamable HTTP, SDK 1.30) con sei strumenti di sola lettura:
      `search_memory`, `get_conversation`, `find_person`, `list_tasks`, `get_day`, `get_week`; testo delle
      persone in campi `quoted`; 60 chiamate al minuto per chiave; registro in `mcp_calls`. In Settings →
      Devices: **Connect an assistant** (chiave, indirizzo, righe per Claude Code e Cursor)
- [ ] Entrambi i casi d'uso (deciso il 16/10): consultare Echo mentre scrivi altrove (connettori di claude.ai e
      ChatGPT, OAuth 2.1, con "Connected apps" in Settings per vedere e revocare) e un assistente che lavora per
      te e consulta le memorie da solo (Claude Code, Claude Desktop, Cursor: chiave di sola lettura nell'header,
      la prima da fare)
- [ ] Più avanti, strumenti che scrivono (creare un task, segnare una promessa come fatta), mai cancellazioni

Un agente per utente — Echo che lavora per te anche quando non glielo chiedi. Un solo motore (l'agente delle
azioni di oggi, in Python) e per ogni utente un profilo nel database; idee prese da eve (Vercel), pi e valet
senza adottarli come runtime (sono TypeScript; eve gira su Vercel):
- [ ] Istruzioni personali ("chiamami Erik, rispondi breve, il lavoro è su Slack") usate da chat, voce e briefing
- [ ] Memoria a grafo: fatti tra persone e cose (soggetto → relazione → oggetto, con "vero da/a" e la frase
      da cui viene) in Postgres, niente database a grafo; nella ricerca si seguono i legami per 1-2 passi
- [ ] Esperimento "Cosa so di te" (16/10: da vedere se funziona): un profilo di fatti stabili, visibile e
      correggibile in Settings, usato in ogni risposta; niente deduzioni su salute, politica, religione, vita sessuale
- [x] Incarichi ricorrenti (22/10): creati a voce o in Ask ("ogni mattina alle 7 dimmi il meteo a Milano"),
      eseguiti dal server all'ora (giornalieri, feriali, settimanali, mensili; max 10), in Profile → Routines;
      senza strumenti che chiedono Confirm
- [x] Incarichi che parlano solo quando serve (28/10, [design](superpowers/specs/2026-10-28-routines-that-speak-when-needed-design.md)):
      tre modi (sempre, solo se vale la condizione, solo le novità), un'esecuzione per riga (`routine_runs`, 90
      giorni), niente più messaggi nel thread; risultati in Today ("From your routines"), in Ask → Routines per
      giorno e per incarico, testo intero con le fonti, "Ask about this" che li porta nella chat. Poi: incarichi
      che creano task o promemoria, notifiche push ad app chiusa (APNs), cambiare il modo dall'app
- [ ] Regole a evento ("quando prometto qualcosa a un cliente, crea un task in Todoist"); azioni verso altri
      sempre con Confirm
- [ ] Dati del proprio agente: quote, pausa di tutti gli incarichi (lo storico delle esecuzioni c'è dal 28/10)
- [ ] Esecuzioni durevoli: ogni passo salvato, un incarico interrotto (riavvio, deploy) riprende da dove era
- [ ] Decisioni veloci (instradamento, "è un comando per Echo?", scelta degli strumenti): prima misurare i tempi
      reali di ogni passo; con molti strumenti (client MCP) scegliere i pertinenti con gli embedding che già
      abbiamo; poi valutare un modello di decisione dedicato come Jev (TypeSafe AI) con `make eval-llm` sui casi
      in italiano. Le conferme restano regole nel codice, mai una probabilità di un modello
- [ ] **Da rivedere (16/10): la chat come un agente, stile Omi.** Oggi ogni domanda va alla memoria (ricerca
      fissa + una risposta) e solo le frasi che nominano un'app passano dal controllo dell'intento; il Task 10
      del piano usage-keys-and-mcp tappa il buco con le istruzioni del modello. Omi invece classifica ogni
      domanda (`requires_context`, modello piccolo): senza contesto → risposta diretta; con contesto → un agente
      con 22+ strumenti (memorie, conversazioni, task, calendario, Gmail, ricerca web) che sceglie cosa
      chiamare e cita le fonti (docs.omi.me, Chat System Architecture). Per Echo: un agente che ha la memoria
      come strumento, riusando i sei strumenti MCP; da pesare la latenza e il costo in più per domanda
- [ ] Idee da Wispr Flow (16/10; app di dettatura senza API, non integrabile): dettatura di Ask trascritta sul
      server con lo stesso modello del dispositivo (più precisa su nomi e italiano, costa per minuto: dopo la
      misura dei costi); un caso di prova per i messaggi dettati con ripensamenti ("alle 8, anzi alle 8 e
      mezza" → "alle 8:30") quando l'agente scrive per l'utente
- [x] Ricerca web (22/10): lo strumento di OpenAI in chat, voce, agente e incarichi, 30 ricerche al giorno per
      utente, contate in `make usage` (0,010 $ l'una, da verificare); fonti mostrate in Ask, mai nella memoria
- [ ] Ricerca web con Perplexity al posto di OpenAI (stessa interfaccia, `services/web_search.py`)
- [ ] Echo come client MCP (24/10: rimandato): per ora tutto resta su Composio, che ha già Notion, Linear,
      GitHub, HubSpot, Jira... (Profile → Apps, ricerca). Prima misurare il costo delle azioni Composio in `make
      usage`; il client MCP diretto (OAuth per servizio, chiavi cifrate per utente, Confirm per ciò che scrive) quando
      servono servizi che Composio non ha, server interni di un'azienda, o i costi crescono. Gmail: niente app Google
      verificata (il controllo CASA costa migliaia di $ l'anno); per la beta, se serve, un'app non verificata (fino a
      100 utenti)
- [ ] Echo con gli agenti di ChatGPT (Dots, OpenAI, 30/09): nessuna API per chiamarli da Echo, ma un Dot può
      usare Echo come fonte tramite il nostro server MCP ("compra il vino di cui ho parlato sabato": Echo dice
      quale, il Dot lo cerca e lo compra con le conferme e i pagamenti di ChatGPT). Da verificare che accettino
      connettori MCP esterni; serve l'accesso con OAuth. Un agente nel browser nostro (Browserbase/Browser Use +
      computer use) no per ora: lento, costoso, senza i login dell'utente; mai acquisti senza Confirm
- [ ] Più azioni: Echo come client MCP (l'utente collega i server MCP che vuole, oltre a Composio); parlare con il
      proprio agente anche da Telegram o Slack, non solo dall'app e dal dispositivo

### Correzioni segnalate il 16/10 (piano usage-keys-and-mcp, Task 10 e 11)
- [x] (16/10) "Cosa sai fare?" in Ask risponde "non ho informazioni nella memoria": Echo deve sapere cosa sa fare,
      rispondere alle domande generali dicendo che non vengono dalla memoria, e non inventare mai il passato
- [x] (16/10) La dettatura in Ask capisce solo l'inglese: una lingua per account ("la lingua che parli"), usata dalla
      trascrizione del dispositivo e dalla dettatura; testo da leggere in Settings → Voices anche in italiano

### Fase 8 — Nuove funzioni (idee del 16/10)
- [ ] Echo riconosce chi hai davanti: quando una voce nota parla, sul telefono "Marco: l'ultima volta ti ha
      detto che aspettava l'esito dell'esame" (dopo circa un minuto: la voce si riconosce sul server)
- [-] ~~Ricordare le persone per te: compleanni ed eventi del calendario~~ (23/10: no, bastano i promemoria
      e il briefing prima degli incontri)
- [ ] Domande che nessun'altra app sa fare, mostrate in "What Echo can do" ("Quando ho visto Marco l'ultima
      volta?", "Quante volte ho promesso di chiamare mia madre?")
- [ ] Il primo giorno: un riepilogo che sorprende entro 24 ore (da provare sui dati veri prima di deciderlo)
- Scartate per ora: "conti in sospeso" (li coprono i task), "un anno fa oggi"
- [ ] Cosa aspetto dagli altri: le promesse fatte a te ("Marco mi manda il preventivo venerdì"), con un
      promemoria se non arriva; "Non parli con Luca da 2 mesi" nella pagina della persona
- [ ] **Saved** (deciso il 16/10, generico il 21/10): le cose da ritrovare, non da fare (quelle restano task,
      Promemoria, Todoist). UN solo tipo di elemento, generico: nome, foto, posto del telefono (solo se chiesto),
      data, campi liberi (un importo…) e il suo momento (conversazione, persone); raccolte create dall'agente da
      quello che dici ("salvami questo", "segnati dove ho messo…", "aggiungi alla lista dei vini"), nessuna
      funzione dedicata per un caso; strumenti per l'agente (salva, trova, somma, togli); una pagina in Memories.
      Parcheggio, passaporto, liste, scontrini sono solo esempi dello stesso meccanismo (il parcheggio il primo
      da provare). Mockup approvati il 16/10 (tela, riga "Saved")
- [ ] Posti: "Echo, salvami questo posto" → Saved, gruppo Places. La posizione si legge SOLO quando l'utente
      chiede di salvare qualcosa (il parcheggio, un posto, una cosa con il suo posto), mai in automatico su
      conversazioni e foto, e niente storico dei posti visitati (deciso il 16/10). Indirizzo dal telefono (gratis); nome del locale da Apple Maps su
      iPhone, su Android dalla foto o con Google Places (a pagamento)
- [ ] Fotocamera, da valorizzare (il vantaggio che gli altri dispositivi non hanno):
  - [ ] **"Dove ho parcheggiato"** (la preferita): "Echo, ricordati dove ho parcheggiato" salva la posizione del
        telefono, solo sul telefono (come Promemoria/Calendario, un comando che l'app esegue); "Dov'è la
        macchina?" risponde con indirizzo e un link alla mappa. Resta finché non salvi un nuovo parcheggio, al
        massimo una settimana, con "Found it" per toglierla (deciso il 16/10; capire da solo che riparti, più avanti). La foto è facoltativa (piano e colonna in un parcheggio coperto). Da verificare: su iPhone
        la posizione con l'app in background può richiedere il permesso "Sempre"
  - [ ] "Dove ho messo il passaporto / le chiavi": "Echo, il passaporto è qui" → "Dov'è il passaporto?" risponde
        con la foto e il posto (la descrizione è già nella memoria: manca il comando e la risposta con la foto)
  - [ ] Scontrini → spese strutturate (negozio, importo, data, categoria): "quanto ho speso questa settimana?"
  - [ ] Liste "salva questo": vini, libri, prodotti, posti ("cos'era quel vino del ristorante di sabato?")
  - [ ] Documenti con scadenza: bollette, lettere, biglietti di treno/aereo → task o evento con la data giusta,
        senza tenere IBAN e codici nella memoria
  - [ ] Azioni dalla foto: locandina → evento in calendario, QR code → link, rete Wi-Fi
  - [x] (16/10) Foto dal telefono quando il dispositivo non può (non collegato, senza fotocamera, in muto): il pulsante
        della fotocamera in Ask apre la fotocamera del telefono (richiesta del 16/10; piano usage-keys-and-mcp, Task 9)
  - [ ] Traduzione al volo (menu, cartelli) tra gli esempi di "What Echo can do"
  - [ ] Doppia pressione del pulsante = "salva e basta" (nessuna risposta), singola = chiedi
  - [ ] Le foto in "Your day" e nel riepilogo della settimana
  - Già fatto: risposta sulla foto, descrizione nella memoria, foto agganciata alla conversazione in corso
    (lavagne e slide in riunione), task ed eventi dalle foto, biglietti da visita → People
  - Esclusi: riconoscimento dei volti (dati biometrici) e scatti automatici continui (batteria, consenso di chi
    è intorno)
- [ ] Resoconto della riunione da inviare: decisioni e cose da fare, "Invia ai partecipanti" con Confirm
- [ ] App web: cercare e leggere le memorie dal computer
- [ ] "Echo Wrapped" settimanale: con chi hai parlato di più, quanto, gli argomenti ricorrenti

## Già fatto

- **Catena di base:** wearable ESP32-S3 (VAD, ADPCM, buffer PSRAM, relay BLE con conferma di upload,
  ADR 0006), backend FastAPI + worker (STT, entità, conversazioni, RAG), Postgres + pgvector, CI completa.
- **Memoria:** riassunti per conversazione, giornalieri e **settimanali**; persone note nell'estrazione;
  deduplicazione; date relative; **ricerca per persona** ("cosa ha detto Marco?"); People con conversazioni e
  task; correzione dei transcript con rianalisi.
- **Voci:** impronte vocali sul server, la tua voce registrata, nomi assegnati dal transcript, "Marco?" quando
  incerto (ADR 0008).
- **Fotocamera:** foto a comando ("Echo, cos'è questo?" o pulsante 📷), risposta in chat e descrizione in
  memoria, nessuna foto conservata sul dispositivo (ADR 0007).
- **Azioni:** Gmail, Calendar, Slack, Telegram, Todoist, Notion via Composio, conferma per ciò che tocca altri,
  registro; richieste vocali "Echo, …".
- **App:** Today / Ask / Memories (Tasks da Today), chat in streaming con fonti, batteria del dispositivo,
  aggiornamento del firmware via Bluetooth, account con accesso e registrazione, tema chiaro/scuro.
- **Modelli:** `gpt-6-luna` per ogni ruolo (analisi, chat, agente, instradamento, visione), Deepgram Nova-3,
  banco di prova per sceglierli ([MODEL-EVALUATION.md](MODEL-EVALUATION.md)).

## Più avanti

- Firmware: wake word sul dispositivo, risparmio energetico (light sleep tra i frame VAD), feedback aptico.
- Hardware del prodotto (22/10; per ora si resta sulla XIAO ESP32-S3 Sense): un circuito fatto apposta con
  ESP32-S3, **due microfoni** (beamforming e meno rumore; la direzione del suono distingue la voce dell'utente da
  quella degli altri, oltre alle impronte vocali), fotocamera e un piccolo **altoparlante** (Echo risponde a voce
  dal dispositivo: costa batteria, la sintesi vocale ha un costo da misurare, e chi è vicino sente). Da provare
  prima su una scheda audio a parte (es. ReSpeaker Lite con XIAO ESP32-S3) come prototipo separato.
- Memoria: filtro per tipo di entità ("i miei task aperti con Marco"), raggruppamento per argomento.
- Provider alternativi e locali: Whisper/LLM/embedding self-hosted, Claude, Gemini.
- Deploy: il server su un VPS in Europa con backup notturni cifrati (oggi gira sul Mac: se è spento, Echo non
  funziona); più avanti un Postgres gestito (backup puntuali, repliche) quando ci saranno clienti.
- Account per la vendita: verifica dell'email e recupero della password via email (serve un servizio di invio),
  verifica in due passaggi, Accedi con Apple/Google.
- Modalità consenso basata sulla voce (testo completo solo per te e per le voci registrate): utile
  quando Echo avrà altri utenti o con le voci collaudate nell'uso reale.
- Multi-utente: account, registrazione e dati separati per utente ci sono; restano quote e costi per utente
  (oggi tutti usano la chiave OpenAI del server), più dispositivi Echo per account, plugin di terze parti.
