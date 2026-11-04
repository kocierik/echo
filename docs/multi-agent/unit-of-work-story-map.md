# Mappa dei requisiti sulle unità

Non esiste `stories.md` (User Stories saltata), quindi le righe sono per requisito funzionale `FR{n}.{m}` da `inception/requirements-analysis/requirements.md`, più le NFR che il piano traccia. Ogni unità nominata su una riga ne traccia tutti i criteri di accettazione nel suo Functional Design.

| ID | Unit | Directory |
|---|---|---|
| FR1.1 | U4 | u4-coordinator-ask |
| FR1.2 | U5 | u5-voice-coordinator |
| FR1.3 | U4 | u4-coordinator-ask |
| FR1.4 | U4 | u4-coordinator-ask |
| FR1.5 | U4 | u4-coordinator-ask |
| FR1.6 | U4 | u4-coordinator-ask |
| FR2.1 | U3 | u3-registry-and-actions-agent |
| FR2.2 | U3 | u3-registry-and-actions-agent |
| FR2.3 | U6 | u6-assistant-agents |
| FR2.4 | U4 | u4-coordinator-ask |
| FR3.1 | U4 | u4-coordinator-ask |
| FR3.2 | U3 | u3-registry-and-actions-agent |
| FR3.3 | U3 | u3-registry-and-actions-agent |
| FR3.4 | U6 | u6-assistant-agents |
| FR4.1 | U4 | u4-coordinator-ask |
| FR4.2 | U3; U4 | u3-registry-and-actions-agent; u4-coordinator-ask |
| FR4.3 | U4 | u4-coordinator-ask |
| FR5.1 | U4 | u4-coordinator-ask |
| FR5.2 | U4 | u4-coordinator-ask |
| FR5.3 | U4 | u4-coordinator-ask |
| FR6.1 | U3 | u3-registry-and-actions-agent |
| FR6.2 | U3 | u3-registry-and-actions-agent |
| FR6.3 | U3 | u3-registry-and-actions-agent |
| FR6.4 | U3; U4 | u3-registry-and-actions-agent; u4-coordinator-ask |
| FR6.5 | U4 | u4-coordinator-ask |
| FR7.1 | U1; U4 | u1-run-foundation; u4-coordinator-ask |
| FR7.2 | U2 | u2-llm-resilience |
| FR7.3 | U3 | u3-registry-and-actions-agent |
| FR7.4 | U2 | u2-llm-resilience |
| FR7.5 | U4 | u4-coordinator-ask |
| FR7.6 | U1; U5 | u1-run-foundation; u5-voice-coordinator |
| FR8.1 | U1; U2 | u1-run-foundation; u2-llm-resilience |
| FR8.2 | U1; U5 | u1-run-foundation; u5-voice-coordinator |
| FR8.3 | U1 | u1-run-foundation |
| FR8.4 | U1 | u1-run-foundation |
| FR8.5 | U3 | u3-registry-and-actions-agent |
| FR8.6 | U1 | u1-run-foundation |
| FR9.1 | U1; U4 | u1-run-foundation; u4-coordinator-ask |
| FR9.2 | U7 | u7-daily-budget |
| FR9.3 | U7 | u7-daily-budget |
| FR9.4 | U7 | u7-daily-budget |
| FR10.1 | U4 | u4-coordinator-ask |
| FR10.2 | U3 | u3-registry-and-actions-agent |
| FR11.1 | U1 | u1-run-foundation |
| FR11.2 | U1; U2; U3; U4; U5; U6; U7 | u1-run-foundation; u2-llm-resilience; u3-registry-and-actions-agent; u4-coordinator-ask; u5-voice-coordinator; u6-assistant-agents; u7-daily-budget |
| FR11.3 | U1 | u1-run-foundation |
| NFR1 | U4 | u4-coordinator-ask |
| NFR2 | U4 | u4-coordinator-ask |
| NFR3 | U4 | u4-coordinator-ask |
| NFR4 | U3 | u3-registry-and-actions-agent |
| NFR5 | U1; U3; U4 | u1-run-foundation; u3-registry-and-actions-agent; u4-coordinator-ask |
| NFR6 | U2; U3 | u2-llm-resilience; u3-registry-and-actions-agent |
| NFR7 | U1 | u1-run-foundation |
| NFR8 | U1 | u1-run-foundation |
| NFR9 | U1; U2; U3; U4; U5; U6; U7 | u1-run-foundation; u2-llm-resilience; u3-registry-and-actions-agent; u4-coordinator-ask; u5-voice-coordinator; u6-assistant-agents; u7-daily-budget |
| NFR10 | U1; U2; U3; U4; U5; U6; U7 | u1-run-foundation; u2-llm-resilience; u3-registry-and-actions-agent; u4-coordinator-ask; u5-voice-coordinator; u6-assistant-agents; u7-daily-budget |
| NFR11 | U1 | u1-run-foundation |

FR10.1 (server MCP invariato) è assegnato a U4 perché è l'unità che cambia la chat: il suo criterio di accettazione è che i test MCP di oggi passino senza modifiche con il coordinatore acceso.

## Requisiti trasversali

- **FR11.2, NFR9, NFR10** — ogni unità: è rilasciabile dietro la sua impostazione, lascia verde la suite esistente e porta la copertura del suo codice nuovo all'80%.
- **FR4.2, FR6.4** — il formato del risultato e il flag non fidato nascono in U3 (adattatore Azioni) e sono usati da U4 (Coordinator).
- **FR7.1, FR9.1** — il budget e la scadenza per richiesta nascono in U1 e sono applicati da U4.
- **FR7.6, FR8.2** — U1 fornisce chiusura delle interrotte e propagazione del correlation ID; U5 le applica alla voce.
- **NFR5** — l'isolamento per utente va verificato in U1 (tracciamento), U3 (strumenti) e U4 (risposte).

## Ordine di implementazione dentro ogni unità

- **U1:** migrazione e modelli → contesto di esecuzione e registrazione dei passi → RequestLimits → correlation ID nelle code → chiusura delle interrotte e retention → `make runs`.
- **U2:** breaker per provider → timeout e retry delle chiamate al modello → addebito dei token e passi `llm_call`.
- **U3:** nuovi ingressi di `run_action_agent` → AgentSpec e registro con validazione → adattatore Azioni → tracciamento delle routine.
- **U4:** DelegationPlan nell'instradatore → MemoryAgent → Coordinator (percorso veloce, piano, propagazione, composizione) → interruttore in `/api/query` (JSON e SSE).
- **U5:** correlation ID nel payload di queue:voice → chiamata al Coordinator → messaggi di fallimento.
- **U6:** risoluzione degli assistenti nel registro → esecuzione con profilo.
- **U7:** calcolo del costo del giorno → limiti per piano → controllo nel Coordinator → costo per agente in `make usage`.

## Verifica della copertura

- Tutti i 46 `FR{n}.{m}` di `requirements.md` hanno almeno un'unità; le 11 NFR sono assegnate.
- Ogni unità ha righe: U1 (17), U2 (7), U3 (18), U4 (26), U5 (6), U6 (5), U7 (6), contando anche le righe trasversali.
