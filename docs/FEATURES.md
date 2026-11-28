# Echo — Cosa fa oggi

> Resoconto al 28/11/2026 di tutto ciò che è implementato e su `main`. Quello che manca è in
> [ROADMAP.md](ROADMAP.md); i dettagli tecnici e i problemi aperti in [PROJECT-STATUS.md](PROJECT-STATUS.md).
>
> L'app ha tre schede: **Today**, **Ask** e **Library** (tutto quello che Echo tiene: giorni, conversazioni,
> persone, to-do, Saved, posti). Impostazioni e dispositivo stanno dietro l'icona della persona in alto,
> qui chiamata **Account**.

## Il dispositivo

- Ascolta da solo quando qualcuno parla (niente wake word) e tiene fino a ~27 minuti di parlato in memoria
  quando il telefono non c'è; con una microSD il resto va sulla scheda (circa 75 ore per GB, Opus a 32 kbit/s) invece di andare
  perso, cifrato con una chiave che non lascia il dispositivo. Today mostra quanti minuti aspettano di essere
  inviati; Account → Echo mostra la scheda (spazio libero, parlato in attesa). Con la scheda il LED resta spento.
- Invia l'audio al telefono via Bluetooth cifrato, con conferma: niente si cancella prima che il server l'abbia.
- Pulsante: pressione breve = foto, lunga = muto/riattiva. Quando arriva la foto il telefono vibra (app aperta)
  o mostra "📷 Photo taken" (app in background).
- Fotocamera su richiesta: una foto alla volta, mai tenuta sul dispositivo.
- Si aggiorna senza cavo: il firmware pubblicato sul server arriva via Bluetooth, controllato, e se la nuova
  versione non si collega torna da solo alla precedente. Dal 0.8.0 accetta solo firmware firmati con la tua
  chiave di rilascio: né il server né il telefono possono installarne uno loro. Firmware attuale 0.10.6.
- Registra solo il parlato: filtro passa-alto e soglia che segue il rumore di fondo (0.10.4), CPU a 160 MHz
  perché non si perda audio (0.10.2), colori più fedeli con poca luce calda (0.10.5).
- Non resta mai irraggiungibile: se nessun telefono è collegato e non si fa trovare, torna a farlo da solo;
  un collegamento che non si completa in 60 secondi viene chiuso e il telefono riprova (0.10.6).
- "Dimentica" funziona anche con il dispositivo lontano o spento: lo dimentica solo il telefono.

## Ricordare

- Trascrizione (Deepgram o OpenAI), divisione in conversazioni, titolo, riassunto ed emoji per ognuna.
- Dalle conversazioni: persone, promesse fatte da te (con la frase d'origine), eventi, idee, note.
- Date e orari relativi risolti ("giovedì alle 3" → la data giusta).
- Riassunto di ogni giorno e di ogni settimana.
- Trascrizione correggibile, con rianalisi della conversazione.
- La lingua che parli si sceglie nel primo avvio, prima di registrare la voce; mentre registri vedi cosa
  Echo sente.
- Altre lingue sentite intorno (fino a 4, Account → Language): Deepgram sceglie solo fra le tue, segmento per
  segmento, con "Translate" nella conversazione. Di default solo la lingua che parli: la modalità multilingue
  di Deepgram scriveva l'italiano in croato e persiano (28/11).
- Le foto scattate in una conversazione entrano nel suo riassunto.

## Chiedere (Ask)

- Domande scritte o dettate (tieni premuto il pulsante Ask): Echo cerca nella memoria, prima tra le persone
  nominate, e risponde nella lingua della domanda, con le fonti che aprono la conversazione.
- Risposta che appare mentre viene scritta.
- Ricerca web per ciò che è attuale (meteo, notizie, prezzi), con i siti citati; 30 ricerche al giorno.
- Un unico thread con Echo (domande, richieste a voce, foto, risultati degli incarichi portati con "Ask
  about this"), più chat a parte con "New chat" e la cronologia.
- Ask → Routines: i risultati degli incarichi per giorno e per incarico.
- Il "+" a sinistra del campo: fotocamera e galleria del telefono, file, app collegate; a destra il
  microfono per dettare.
- Ritentare non esegue due volte: la risposta già pronta torna indietro.

## Today

- In cima solo le azioni da confermare; poi le sezioni nell'ordine che scegli ("Edit Today" nasconde e sposta):
  - From your routines;
  - To do today;
  - Coming up today, con "Last time: …";
  - Your day (conversazioni e foto, quella in corso dal vivo);
  - People;
  - Saved;
  - Where you've been;
  - Earlier days.
- Funziona anche offline dalla copia sul telefono ("Offline · updated 14:32").
- Tasks: da fare per scadenza, completa con Annulla, "Not a task".

## Persone e voci

- People: ultima volta viste, ruolo e note, task ed eventi che le nominano, conversazioni, "Ask about".
- La tua voce registrata (Account → Voices) e i nomi degli altri dati toccando una riga del trascritto; Echo
  poi scrive i nomi e chiede "Marco?" quando è incerto.
- Le impronte si confrontano togliendo il suono del ciondolo (con un solo microfono tutti si somigliano); un
  segmento forte, vicino al microfono, non viene mai dato da solo a un'altra persona.
- Più voci nello stesso segmento: a conversazione chiusa pyannoteAI (Parigi) dice chi parla quando sull'audio
  intero; nelle prove su riunioni vere sbaglia una parola su 50-100, contro una su 6-10 di Deepgram. Ogni
  blocco si può nominare. Senza la chiave di pyannoteAI restano le voci separate da Deepgram.
- Chi hai davanti: quando parla una voce che hai nominato, subito una notifica con le promesse nei due sensi e
  l'ultima conversazione.

## Fotocamera

- "Echo, cos'è questo?" o il pulsante del dispositivo; con il dispositivo non disponibile, la fotocamera del
  telefono.
- Una foto capovolta o di lato viene raddrizzata e guardata di nuovo; in una foto scura o mossa Echo non tira
  a indovinare, e dice quando il ciondolo era girato.
- "Spiegami che statua ho davanti": una domanda su qualcosa che il web conosce (monumenti, opere, piante,
  prodotti) usa la ricerca web, con le fonti; nella memoria resta solo quello che mostrava la foto.
- Risposta in chat con la miniatura e le azioni rapide: Translate, Ask more, Remind me (se la foto mostra una
  data).
- Descrizione nella memoria; foto agganciata alla conversazione in corso (lavagne, slide).
- Task ed eventi dalle foto (una locandina → un evento); biglietto da visita → persona in People.

## Saved e posti

- Saved: cose da ritrovare, non da fare. Esempi:
  - "ricordati dove ho parcheggiato" (con la foto del posto e la posizione del telefono; un nuovo
    parcheggio sostituisce il vecchio); "salva questo posto" salva solo la posizione, senza foto;
  - "il passaporto è qui" (con la foto e il posto);
  - "salvami questo vino";
  - gli scontrini, e "quanto ho speso questa settimana?" fa la somma.
- Liste create da Echo da quello che dici; in Today → Saved e nei chip delle risposte.
- La posizione del telefono si legge solo quando chiedi di salvare qualcosa; indirizzo e link alla mappa.
- Places visited (Account, spento di default, 90 giorni): i posti di oggi in Today e il posto di una
  conversazione.

## Agire sulle app

- Gmail, Google Calendar, Slack, Telegram, Todoist, Notion e altre app cercabili, via Composio (Account → Apps).
- Promemoria e Calendario dell'iPhone senza Composio.
- Leggere e creare subito; mandare ad altri, modificare e cancellare aspettano il tuo **Confirm**.
- Registro di ogni azione (Account → Activity).
- To-do: dalle conversazioni nascono solo le tue promesse esplicite; gli altri li chiedi tu ("segnami…").

## Richieste e risposte a voce

- "Ehi Echo, …" (anche "Echo, …", "Eco, …"), anche dopo altre frasi nella stessa registrazione: la risposta
  arriva nel thread in Ask, con una notifica.
- Spoken answers (Account): il telefono legge la risposta ad alta voce, solo in cuffia o anche
  sull'altoparlante, anche a schermo bloccato; Echo non registra mentre il telefono parla.

## Incarichi (routine)

- "Ogni mattina alle 7 dimmi che tempo fa a Milano": giornalieri, feriali, settimanali o mensili, al massimo 10.
- Tre modi: dice sempre, solo se vale la condizione ("dimmi se piove"), solo le novità.
- Anche dopo ogni conversazione, sul testo appena detto ("dopo ogni riunione scrivimi chi fa cosa"): basta
  l'istruzione, senza codice.
- Catalogo di incarichi e assistenti pronti, aggiunti con un tocco: Ask → Routines → Add, il "More" degli
  assistenti in Ask, Account → Routines.
- Risultati in Today, in Ask → Routines e come notifica; pausa e cancellazione in Account → Routines.

## Echo per te

- Istruzioni (Account → Instructions): come deve risponderti, in ogni risposta in chat e a voce.
- About you (Account → Memory):
  - frasi su di te usate in ogni risposta;
  - Echo ne propone dalle conversazioni e le usa solo se le tieni;
  - "ricordati che…" / "dimentica che…" le cambiano a voce.
- Documenti (Account → Memory): PDF, Word, testo, Markdown cercati quando Echo risponde, nominando il
  documento; si tiene solo il testo.
- Assistenti (Account → Assistants):
  - Lavoro, Dieta, Sonno o creati da zero;
  - ognuno con istruzioni, note che aggiorna da solo e documenti scelti;
  - una chat con loro in Ask, e gli incarichi creati nella loro chat girano come loro;
  - mai consigli medici.

## WhatsApp (in lettura, non ufficiale)

- Collega il tuo numero con un codice (Account → WhatsApp) e chiedi "cosa mi ha scritto Marco?", anche negli
  incarichi.
- Solo chat private, nessun invio, messaggi solo in memoria per 7 giorni. WhatsApp può bloccare il numero.

## Notifiche ("Echo viene da te")

- Promesse da mantenere: la mattina della scadenza, e in Today.
- Briefing 10 minuti prima di un incontro, solo se c'è qualcosa da sapere sulla persona.
- Riepilogo serale (spento di default).
- Al massimo tre al giorno, mai tra le 22 e le 8, ognuna spegnibile.
- iPhone: Live Activity sulla schermata di blocco e nella Dynamic Island (ascolta, muto, offline, batteria,
  minuti da inviare).

## Account, privacy e dispositivi

- Primo avvio con benvenuto animato, accesso o registrazione con email e password o con Google, permessi,
  lingua, voce, abbinamento.
- Una chiave per telefono, revocabile (Account → Devices); password Argon2, tentativi limitati.
- Condividere una conversazione (testo o Markdown); export di tutti i tuoi dati in JSON (Account → Privacy).
- Audio cancellato dopo l'elaborazione (24 h; 7 giorni se incompleto).
- Tema chiaro, scuro o di sistema.

## Fuori da Echo

- Server MCP: Claude, Cursor e altri assistenti leggono le tue memorie con una chiave di sola lettura
  ("Connect an assistant" in Account → Devices). Sei strumenti: cerca, conversazione, persona, task, giorno,
  settimana.

## Sul server

- Costi per utente e per giorno (`make usage`: costo di un giorno e di un'ora di parlato).
- `gpt-6-luna` per ogni ruolo dei modelli, scelto con un banco di prova (MODEL-EVALUATION.md).
- Code con ritentativi, circuit breaker e coda degli errori; metriche Prometheus.
- App Android: si compila dallo stesso codice, non ancora provata con il dispositivo.
