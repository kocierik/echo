# Motivi dell'ordine e rischi

Un **Bolt** è un giro di costruzione su un pezzo del lavoro che finisce con qualcosa che gira e si può provare; qui ogni Bolt è una unità di lavoro (`bolt-plan.md`).

## Euristica scelta

**Prima la base obbligatoria, poi il valore** (risposta Q1), senza un modello di punteggio formale come WSJF (Q2): con 7 unità e un DAG stretto (`inception/units-generation/unit-of-work-dependency.md`) l'ordine segue dalle dipendenze e dall'obiettivo della persona, cioè "la chat come coordinatore" come primo risultato (Q1 dei requisiti). È la combinazione di "foundation first" e "value-first" della guida di pianificazione; dove serve, si anticipa il rischio principale (Q6).

| Posizione | Bolt | Perché qui |
|---|---|---|
| 1 | U1 base | Tutte le altre unità ne dipendono; nessun valore visibile, ma senza tracciamento non si può misurare nulla di ciò che segue (NFR1, NFR7) |
| 2 | U3 registro e Azioni | Prerequisito di U4; contiene il rischio principale (toccare il percorso delle conferme), che conviene affrontare presto, con test prima e dopo (Q6) |
| 3 | U4 coordinatore Ask | Il primo risultato chiesto (Q1 dei requisiti); dietro impostazione spenta, quindi rilasciabile anche prima di U2 |
| 4 | U2 resilienza | Va prima dell'accensione in produzione del coordinatore: senza timeout e breaker per provider il percorso sincrono resta fragile come oggi |
| 5 | U5 voce | Estende a voce ciò che U4 ha provato in Ask; richiede una prova reale col wearable |
| 6 | U6 assistenti | Valore aggiuntivo che dipende solo da U3; dopo la voce perché la voce era nella risposta Q1 dei requisiti ("Ask e voce") |
| 7 | U7 budget giornaliero | Ha bisogno dei costi misurati dai Bolt precedenti per fissare limiti sensati (Q5, ROADMAP "prima misurare") |

## Deviazioni dall'ordine topologico

Nessuna deviazione: ogni Bolt viene dopo le unità da cui dipende. L'unica scelta non obbligata è U3 prima di U2 (indipendenti nel DAG): motivata dal valore (U4 prima possibile) e dal rischio principale (U3 tocca le conferme). Se il sistema di costruzione propone U2 prima di U3, l'ordine resta valido.

## Registro dei rischi

| Rischio | Probabilità | Impatto | Mitigazione | Bolt |
|---|---|---|---|---|
| Rompere conferme, pending action o `_LASTING_OWN` modificando `run_action_agent` (rischio principale, Q6) | Media | Critico | Test che fissano il comportamento di oggi prima di toccare il codice, eseguiti prima e dopo; parametri nuovi tutti opzionali con default = oggi; NFR4 su tutti gli strumenti propri e un campione Composio | 2 |
| Import circolari spostando l'oscuramento in `core` | Media | Medio | Test di import in CI (C1); `actions/audit.py` importa da `core/redaction.py`, mai il contrario | 1 |
| Il tetto di token si consuma con unità che non sono token (STT in secondi, embedding) | Media | Medio | Addebito solo per i `kind` di completamento del modello (punto R-01 della revisione dei contratti, da fissare nel Functional Design di U1) | 1 |
| Durata reale della richiesta oltre il timeout dell'app (sintesi e retry dopo la scadenza) | Media | Medio | Limite superiore completo e trattamento della sintesi dopo la scadenza da fissare nel Functional Design di U4 e nelle NFR (punto R-02 della revisione dei contratti) | 3, 4 |
| La chat diventa più lenta o più costosa | Bassa | Alto | Percorso veloce senza chiamate in più (FR1.3); misura del p95 prima e dopo (NFR1); coordinatore spento di default | 3 |
| Il piano sceglie l'agente sbagliato in italiano | Media | Medio | Casi nuovi nelle eval in italiano (`make eval-llm`) prima di accendere il coordinatore; al più 3 passi per piano | 3 |
| Un contenuto letto guida un altro agente (injection) | Bassa | Alto | Propagazione del non fidato (ADR-006); test con un'email che contiene istruzioni | 2, 3 |
| Prezzi in `usage_prices.py` sbagliati falsano il budget | Media | Basso | Verifica dei prezzi prima di U7 (Q5); limiti come impostazioni modificabili | 7 |
| Copertura del codice nuovo non misurabile oggi (nessuna misura in CI) | Alta | Medio | Aggiungere la misura della copertura nel Bolt 1, così vale per tutti i Bolt | 1 |

## Fonti

`inception/requirements-analysis/requirements.md`, `inception/domain-design/components.md` e `decisions.md`, `inception/units-generation/unit-of-work.md` e `unit-of-work-dependency.md`, `inception/contract-design/contract-summary.md`, risposte in `delivery-planning-questions.md`.
