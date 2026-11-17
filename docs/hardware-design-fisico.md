# Echo: il design fisico

Note del 17 novembre 2026: le idee discusse per la nuova forma del dispositivo, le scelte fatte
e i motivi, cosa resta da misurare. Il dispositivo di oggi (XIAO ESP32-S3 Sense, batteria
103040 da 1200 mAh, guscio stampato) è troppo grande e scalda.

## Cosa vogliamo

- Si indossa **sia al polso sia al collo**, passando da uno all'altro.
- **Stile premium, alla Apple.**
- La foto la scatta l'utente **puntando il dispositivo con la mano**: la fotocamera non deve
  guardare sempre avanti da sola.

## Le scelte, nell'ordine in cui sono state fatte

1. **Scartato:** il "sasso" rotondo con clip magnetica sul petto e gli anelli azzurri attorno
   all'obiettivo. Non piaceva lo stile.
2. **La foto si scatta a mano.** Cade il vincolo più forte: la fotocamera non deve più puntare
   avanti in ogni momento.
3. **Tra le forme considerate restano lo stilo da collo (A) e la pastiglia da polso (C),
   intercambiabili.**
4. **Stile Apple:** alluminio anodizzato, nessuna vite a vista, dettagli nascosti.
5. **Lo stilo non serve più.** Al collo va una **medaglia piatta con la batteria grande**
   dentro, sul modello del MagSafe Battery Pack.

## Il concetto scelto: un nucleo e due supporti

Un **nucleo** piccolo contiene tutta l'elettronica e una batteria piatta. Si aggancia con un
magnete a uno di due supporti:

| | Al polso | Al collo |
|---|---|---|
| Supporto | Cornice in alluminio con anse standard da 20 mm a sgancio rapido: accetta qualsiasi cinturino in commercio | Medaglia piatta in alluminio con il passante per il cordino |
| Batteria | Solo quella del nucleo | Quella del nucleo, più quella della medaglia che la ricarica dai contatti a molla |
| Autonomia (stima) | 3–4 ore | Tutto il giorno |
| Foto | Punti il polso | Prendi la medaglia in mano e la punti |
| Microfono | Lontano dalla bocca: serve più guadagno | Vicino alla bocca |

**Perché la medaglia con batteria:** al collo Echo si porta tutto il giorno, ed è lì che deve
ascoltare di più. Se al collo bastassero poche ore, la medaglia diventerebbe una semplice
cornice con il passante, senza batteria né contatti: più sottile e più semplice da costruire.

### Il nucleo

- Forma: capsula a stadio, con raccordi a curvatura continua (gli angoli morbidi di AirPods e
  AirTag, non i raccordi a raggio semplice).
- Fotocamera **su un lato corto**: al polso guarda verso le dita; al collo la punti tenendo la
  medaglia in mano.
- **Riconosce da solo il supporto:** se i contatti sono alimentati è nella medaglia (collo),
  altrimenti al polso. Così il firmware sceglie da solo il guadagno del microfono (la
  regolazione dall'app esiste già, dalla 0.9.3).

### Elettricamente

- La medaglia porta un piccolo circuito di carica che **alimenta il nucleo dai contatti a
  molla**, come una power bank.
- **Mai due batterie LiPo collegate direttamente in parallelo:** se le tensioni sono diverse
  passa una corrente forte e pericolosa.
- Nel primo prototipo la medaglia può alimentare il nucleo anche con un cavetto; i contatti a
  molla vengono dopo.

## Lo stile

- **Guscio:** alluminio anodizzato e sabbiato, monoblocco, senza viti a vista. Nei prototipi le
  viti sul retro vanno bene.
- **Davanti:** una sola finestra in vetro scuro, che contiene l'obiettivo.
- **Luce nascosta:** il LED sta dietro micro-fori invisibili nell'alluminio. Da spento la
  superficie è liscia; quando scatta una foto appare un puntino di luce, visibile anche a chi
  ti sta davanti.
- **Microfono:** un solo foro forato al laser, sul bordo superiore.
- **Tasto:** a filo, corsa corta, dello stesso alluminio. I gesti restano quelli di oggi:
  pressione breve per la foto, 1,5 s per il muto, 5 s per spegnere.
- **Aggancio magnetico** in stile MagSafe: magneti di allineamento e contatti a molla, il
  nucleo scatta in posizione da solo.
- **Cordino** in tessuto intrecciato o pelle. **Cinturino:** qualsiasi da 20 mm. Nessun
  attacco proprietario copiato da Apple.
- **Colori:**
  - nero siderale, con l'anello di luce azzurro del tema dell'app;
  - argento;
  - blu profondo.
- **Nessun logo in vista:** al massimo "Echo" inciso al laser sul retro.

## Tre problemi tecnici del metallo

1. **Il Bluetooth non attraversa l'alluminio.** Sopra l'antenna serve una zona non metallica:
   la finestra di vetro, oppure una banda in ceramica o plastica sul bordo (le "linee
   d'antenna" di Apple). Senza, il dispositivo perde il collegamento col telefono.
2. **La fotocamera** vuole un vetro piano e pulito davanti, non una superficie curva.
3. **Il calore:** l'alluminio dissipa bene il tepore del chip, ma un guscio di metallo caldo
   si sente di più sulla pelle, soprattutto al polso. Serve un fondello in ceramica o un
   isolamento interno.

## Cosa occupa spazio, e perché

- La scheda di oggi è piccola: la XIAO ESP32-S3 Sense misura 21 × 17,8 × 15 mm con la
  fotocamera. **Lo spazio lo prende la batteria**, e la batteria la decide il consumo.
- La **fotocamera è già spenta tra una foto e l'altra**: il firmware la avvia a ogni scatto
  (`firmware/src/camera_capture.h`). Da lì non si guadagna nulla.
- Il consumo stimato è **60–110 mA, mai misurato**. Mentre ascolta, il chip non può dormire:
  il microfono PDM ha bisogno del clock I2S sempre attivo.

| Fase | Elettronica | Nucleo (stima) | Polso | Collo |
|---|---|---|---|---|
| **Subito** | XIAO Sense di oggi | circa 36 × 25 × 16 mm, batteria piatta da ~250 mAh | 3–4 ore | tutto il giorno, con 1200 mAh nella medaglia |
| **Dopo** | Scheda su misura: ESP32-S3-PICO-1 (chip con la memoria integrata), microfono MEMS PDM, fotocamera su flat, circuito di carica, tutto su un disco | circa Ø 30 × 10 mm | come sopra | come sopra |
| **Più avanti** | Un chip a basso consumo (Nordic) sempre acceso per l'audio, l'ESP32 svegliato solo per le foto | da valutare | tutto il giorno | tutto il giorno |

- La scheda su misura rende il nucleo **più sottile**, non più duraturo.
- Per un polso che duri tutto il giorno serve un chip che consumi molto meno mentre ascolta. I
  chip Nordic non sanno gestire la fotocamera, quindi servono due chip: è il progetto più
  complesso, da affrontare solo se il polso diventa il modo principale di usarlo.

## Il percorso

1. **Misurare la corrente:** un misuratore USB da una decina di euro tra il cavo e la scheda,
   mentre ascolta in silenzio, mentre registra e mentre trasmette. Da quel numero dipendono
   tutte le batterie.
2. **Misurare col calibro:**
   - scheda con fotocamera montata (lunghezza, larghezza, altezza totale);
   - tasto;
   - batteria piatta scelta per il nucleo;
   - antenna a flat della XIAO.
3. **Modelli 3D parametrici** in **build123d** (CAD in Python). OpenSCAD non fa raccordi a
   curvatura continua. Il modello esporta STEP per la fresatura e STL per la stampa.
4. **Prototipi in resina SLA**, carteggiati, con primer e vernice metallizzata: per indossarli
   una settimana, provare gli incastri e fare le foto.
5. **Firmware:** riconoscimento del supporto dai contatti e guadagno del microfono per
   ciascuno. È una modifica piccola.
6. **Alluminio fresato CNC**, sabbiato e anodizzato, da servizi online (PCBWay, JLCCNC): il
   primo esemplare premium. Il costo è nell'ordine delle decine di euro a pezzo in piccole
   quantità; il preventivo vero si fa con il file STEP.
7. **Scheda su misura**, se le dimensioni convincono ma lo spessore no.

## Considerate e scartate

| Idea | Perché no |
|---|---|
| **Sasso con clip sul petto** (primo concetto) | Non piaceva lo stile. Tecnicamente era il migliore per la fotocamera, prima che si decidesse di puntarla a mano. |
| **Collana libera** (come Omi) | La fotocamera ruota e pende, l'audio dondola e batte sui bottoni. Con la foto a mano e l'aggancio magnetico il problema si riduce. |
| **Stilo da collo (A)** | Lungo, e una forma diversa dalla pastiglia. Il suo compito, portare la batteria grande, passa alla medaglia piatta. |
| **Piastrina militare (B)** | Batteria più piccola, circa due terzi dell'autonomia di oggi. |
| **Moschettone (D)** | Lontano dalla bocca quando è appeso in basso. |
| **Orologio con la fotocamera che guarda avanti** | Al polso inquadra la manica. Con la foto a mano il polso rientra, ma con poca autonomia (vedi sopra). |

## Omi, per confronto

Omi si porta come collana o al polso, ed è grande quanto un dollaro d'argento, in alluminio
(Decrypt). La durata dichiarata cambia da fonte a fonte: 10–14 ore secondo Omi, "diversi giorni"
in un articolo del 2025. Omi non ha una fotocamera nel ciondolo: la fotocamera è ciò che
distingue Echo, e anche ciò che lo vincola di più.

## Da decidere

- Al polso bastano 3–4 ore per la prima versione, o deve durare tutto il giorno da subito?
- Colore di partenza: nero, argento o blu.
- Cordino: tessuto o pelle.
- Medaglia con batteria (consigliata) o cornice semplice.

## Non ancora verificato

- Il consumo reale del dispositivo: tutte le autonomie qui sono stime.
- Le dimensioni dell'ESP32-S3-PICO-1 e lo spessore reale della scheda montata.
- La capacità esatta delle batterie piatte candidate.
- Quanto attenua il Bluetooth un guscio in alluminio con la finestra d'antenna.
- I costi di fresatura e anodizzazione: nessun preventivo chiesto.
- Peso e batteria di Omi: le fonti non li riportano.

Fonti su Omi:
- [Decrypt](https://decrypt.co/315375/omigpt-aims-smarter-ai-wearable)
- [designboom](https://www.designboom.com/technology/wearable-ai-device-omi-reads-minds-completes-tasks-01-10-2025/)
- [guida Omi 2026](https://www.omi.me/pages/learn-best-ai-wearable-2026)
