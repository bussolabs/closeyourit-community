# Codici errore — `R{STATUS}-{DOMINIO}-{SEQ}`

Formato `R{HTTP_STATUS}-{DOMINIO}-{SEQ}` (rules/error-handling.md). Envelope API: `{ error: { code, message, details? } }`.

## Domini

### AUTH — autenticazione/autorizzazione API
- `R401-AUTH-001` — token API mancante o non valido (anche revocato)
- `R403-AUTH-002` — token privo dello scope richiesto (`TokenAuthentication#require_scope!`)

### TOKEN — gestione credenziali ingest (`Projects::Token`)
- `R422-TOKEN-001` — emissione token fallita (validazione)
- `R422-TOKEN-002` — revoca fallita
- `R422-TOKEN-003` — rotazione fallita

> **Scope del token (`projects_tokens.scopes`, CYRA-37)**: un bearer `cyi_` è SERVER-ONLY e porta due
> scope, applicati da `TokenAuthentication#require_scope!`:
> - **`ingest`** — push di telemetria (`POST /api/v1/projects/:id/{events,metrics,logs,pageviews,replays}`,
>   `crons/:slug/check_in`, `releases#create`).
> - **`read`** — lettura/gestione della telemetria del progetto (`error_groups`, `metric_groups`,
>   `log_entries`, triage `resolution`/`mute`, `analytics#show`, `releases#index`).
>
> `Issue` emette di default un token a **piena potenza** (`["ingest", "read"]`); un token ristretto
> (es. futuro browser-safe) si crea con `scopes: ["ingest"]` e riceve **403 `R403-AUTH-002`** sui read.
> Vedi `../closeyourit-docs/decisions/2026-07-09-cyi-token-server-only.md`.

### CLIAUTH — token utente CLI + device-flow (`Accounts::ApiToken`, `Accounts::Devices::*`)
- `R401-CLIAUTH-001` — token CLI mancante/non valido (sconosciuto **o revocato**); device_code sconosciuto (`invalid_grant`)
- `R401-CLIAUTH-002` — token CLI **scaduto** (CYRA-717): `details.expired_at` = istante di scadenza. Distinto da `-001` perché manda a fare una cosa diversa (rifare `login`, non cercare un errore di copia); la **revoca ha la precedenza** sulla scadenza, un token revocato risponde sempre `-001`
- `R403-CLIAUTH-002` — permesso negato (gate `Authorization::Resolver#can?` su scope visibile)
- `R422-CLIAUTH-001` — emissione `Accounts::ApiToken` fallita (validazione)
- `R422-CLIAUTH-002` — token perpetuo chiesto per un account **umano** (CYRA-717): `expires_at: nil` esplicito è consentito ai soli account di servizio; senza scadenza esplicita il token nasce a `Accounts::Constants::API_TOKEN_DEFAULT_LIFETIME_DAYS` giorni
- `R400-CLIAUTH-002` — `authorization_pending` (poll: non ancora approvato)
- `R400-CLIAUTH-003` — `slow_down` (poll troppo frequente)
- `R400-CLIAUTH-005` — `access_denied` / `expired_token` (concessione negata, scaduta o già consumata)

### INGEST — ingest eventi (Fase 2, error monitoring)
- `R422-INGEST-001` — envelope/evento malformato
- `R413-INGEST-001` — payload troppo grande (limite compresso/decompresso)
- `R413-INGEST-003` — body of any ingest channel without its own cap (logs, pageviews, replays, web vitals, help desk) over `Api::V1::IngestBaseController::MAX_BYTES`, checked on `content_length` before auth and parse — CYRA-1039
- `R413-INGEST-002` — evento `POST /events` oltre `Errors::Constants::EVENTS_MAX_BYTES` (byte del singolo evento, gate su `content_length` in testa alla catena via `prepend_before_action` → precede auth e parse; distinto da INGEST-001 che è l'envelope Sentry compresso/decompresso del DSN pubblico) — CYRA-112
- `R403-INGEST-002` — origine non consentita dall'allowlist del progetto sul public ingest (richiesta browser con header `Origin` non elencato; CYRA-109). Trasversale a tutti i canali di ingest (`IngestAuthentication#enforce_origin_allowlist!`). Difesa AGGIUNTIVA, non autenticazione: senza `Origin` (client non-browser) o con allowlist vuota → passa sempre.
- (riservato: `R429-INGEST-001` — quota ingest per-progetto, via rack-attack throttle `ingest/project`)

### HELPDESK — help desk requests from the sites (CYRA-940)
- `R422-HELPDESK-001` — request not valid: message missing or too long, email not an address
- `R422-HELPDESK-002` — the request is no longer new: already a ticket, linked or discarded (CYRA-941)
- `R422-HELPDESK-003` — the ticket to link is not in the request's project (CYRA-941)
- `R422-HELPDESK-004` — no address to answer to: the visitor left none, or it was erased (CYRA-943)
- `R422-HELPDESK-005` — too many answers on one request (CYRA-943)
- `R403-HELPDESK-001` — the project does not accept help desk requests (switch off in its settings)
- `R404-HELPDESK-001` — the project in the address is not the one of the credential
- (reserved: `R429-HELPDESK-001` — too many requests, through the rack-attack throttles `helpdesk/project` and `helpdesk/ip`)

### ERROR — error monitoring (Fase 2)
- `R422-ERROR-001` — gruppo già promosso a ticket (`Errors::PromoteToTicket`; CLI `Cli::V1::ErrorGroups::PromotionsController`)
- `R422-ERROR-002` — azione di triage non valida (`Errors::Triage`)

### METRIC — ingest metriche performance (`Api::V1::MetricsController`, `Metrics::Ingest::*`) + promote (`Metrics::PromoteToTicket`, CLI `Cli::V1::MetricGroups::PromotionsController`)
- `R422-METRIC-001` — metrica malformata (body non parsabile) **e** gruppo-metrica già promosso a ticket — collisione storica sullo stesso codice (da ripulire).
- `R422-METRIC-002` — `kind` non valido in ingest (atteso `slow_query`/`slow_method`/`performance_issue`)
- `R422-METRIC-003` — `performance_issue` senza `subtype` (richiesto: `n_plus_one`/`slow_request`/`slow_external_http`/`high_query_count`)
- `R413-METRIC-004` — batch di metriche troppo grande (oltre `Metrics::Constants::MAX_BATCH`, NUMERO di campioni)
- `R422-METRIC-005` — azione di triage non valida (`Metrics::Triage`; CYRA-45, speculare a `R422-ERROR-002`)
- `R413-METRIC-006` — batch di metriche oltre `Metrics::Constants::MAX_BYTES` (byte del batch, gate su `content_length` in testa alla catena via `prepend_before_action` → precede auth e parse; distinto da METRIC-004 che limita il NUMERO di campioni) — CYRA-112

### LOG — ingest log strutturati (`Api::V1::LogsController`, `Logs::Ingest::*`) + link manuale (`Logs::Links::*`)
- `R422-LOG-001` — log malformato (body non parsabile)
- `R404-LOG-001` — progetto del path ≠ progetto del token (anti-BOLA)
- `R413-LOG-002` — batch troppo grande (oltre `Logs::Constants::MAX_BATCH`)
- `R422-LOG-003` — collegamento log↔errore/ticket fallito (tipo non ammesso o linkable di un altro progetto)
- `R422-LOG-004` — batch non vuoto interamente non valido (nessun item con message valido: tutti scartati)
- (riservato: `R429-LOG-001` — quota ingest per-progetto, via rack-attack throttle `logs/project`)

### PAGEVIEW — ingest web analytics (`Api::V1::PageviewsController`, `Analytics::Ingest::*`)
- `R422-PAGEVIEW-001` — pageview malformato (body non parsabile)
- `R404-PAGEVIEW-001` — progetto del path ≠ progetto del token (anti-BOLA)
- `R413-PAGEVIEW-002` — batch troppo grande (oltre `Analytics::Constants::MAX_BATCH`)
- `R422-PAGEVIEW-004` — batch non vuoto interamente non valido (nessun item con hostname+path validi)
- (nota: richiesta da bot/crawler → `202 {accepted: 0}`, non è un errore del client)

### GOAL — goal/conversioni analytics (`Analytics::Goals::*`, `Member::Monitoring::Analytics::GoalsController`)
- `R422-GOAL-001` — goal non valido (validazioni: display_name/path_pattern/event_name, unicità per progetto)

### ANALYTICS — stats API di lettura (`Api::V1::AnalyticsController`)
- `R404-ANALYTICS-001` — progetto del path ≠ progetto del token (anti-BOLA)

### LINK — link pubblico di condivisione/embed analytics (`Analytics::Links::*`)
- `R422-LINK-001` — link non valido (validazioni). Nota: accesso pubblico a slug inesistente/revocato → `404` (mai `403`).

### PROJECT — progetti + gruppi (creazione via CLI, `Cli::V1::{Projects,Groups}Controller`)
- `R422-PROJECT-001` — creazione progetto fallita (validazione: name/key blank, key fuori formato `[A-Z0-9]`, key duplicata per org)
- `R422-PROJECT-002` — gruppo riferito (group_id/group_name) inesistente nell'organizzazione (anche anti-BOLA: gruppo di un'altra org)
- `R422-GROUP-001` — creazione gruppo fallita (validazione: name blank)

### ENVIRONMENT — environment org-level (CRUD via CLI, `Cli::V1::EnvironmentsController`)
- `R422-ENVIRONMENT-001` — create/update/destroy environment fallito (validazione: code blank/fuori formato `[a-z][a-z0-9_]*`/duplicato per org, label o color blank; oppure destroy bloccato da progetti/token/monitor che lo referenziano `restrict_with_error`)

### RBAC — ruoli + team via CLI (`Cli::V1::{Roles,Teams}Controller`)
- `R422-ROLE-001` — creazione/aggiornamento ruolo fallito (validazione: name blank o duplicato per org)
- `R422-TEAM-001` — creazione/aggiornamento team fallito (validazione: name blank o duplicato per org)

### ACCESS — assegnazione di ruoli/permessi/scope (`Authorization::Set*`, `Teams::Set*`, condivisi Member + CLI)
- `R403-ACCESS-001` — privilege-escalation: l'attore sta concedendo permessi/ruoli che NON possiede. Regola STRETTA "non puoi concedere ciò che non possiedi" applicata da `Authorization::GrantGuard` (fail-fast, nessuna mutazione) a `Authorization::{SetRolePermissions,SetAccountPermissions,SetAccountRoles}` e `Teams::SetTeamRoles`: una chiave org-level non nei permessi effettivi dell'attore, o QUALSIASI chiave scoped (un Role/override org-wide la concederebbe oltre lo scope per-progetto dell'attore), è vietata a un non-owner. `details.forbidden_keys` elenca le chiavi rifiutate. Owner/god (unscoped) e attore assente (seed/InstallDefaults) sono esenti.
- `R422-ACCESS-002` — assegnazione scope team (progetti/gruppi) fallita (`Teams::SetTeamScope`, rescue difensiva su create!)
- `R422-ACCESS-003` — assegnazione ruoli team fallita (`Teams::SetTeamRoles`)
- `R422-ACCESS-004` — impostazione chiavi-permesso di un ruolo fallita (`Authorization::SetRolePermissions`)
- `R422-ACCESS-005` — assegnazione ruoli diretti a un account fallita (`Authorization::SetAccountRoles`, es. account non membro dell'org)
- `R422-ACCESS-006` — impostazione override personali allow/deny fallita (`Authorization::SetAccountPermissions`, es. account non membro)
- `R422-ACCESS-007` — assegnazione membri a un team fallita (`Teams::SetTeamMembers`)

### INVITE — inviti all'organizzazione (`Connections::InviteMember`, `Cli::V1::InvitationsController`)
- `R422-INVITE-003` — ruolo non ammesso (solo member/admin/customer)
- `R422-INVITE-004` — l'email è già membro dell'organizzazione
- `R422-INVITE-005` — creazione invito fallita (validazione: email mancante/invalida o duplicata)

### PLATFORM — piattaforme org-scoped (`Types::Platform`, `Cli::V1::PlatformsController`)
- `R422-PLATFORM-001` — create/update/destroy piattaforma fallito (validazione: code/label/color blank, code fuori formato `[a-z][a-z0-9_]*`, code duplicato per org; oppure destroy bloccato perché referenziata da progetti/ticket)

### ORGANIZATION — impostazioni org via CLI (`Cli::V1::OrganizationsController`)
- `R422-ORGANIZATION-001` — aggiornamento org fallito (validazione: name/slug blank, slug duplicato o fuori formato `[a-z0-9-]`, `default_projects_view` non ammesso)

### TICKET — ticketing: ciclo di vita (service `Ticketing::*`, condivisi da CLI `Cli::V1::Tickets*` e area Member)
- `R404-TICKET-001` — progetto del ticket non visibile/inesistente nello scope (anti-BOLA, `Ticketing::CreateTicket`)
- `R404-TICKET-002` — progetto non visibile per gli assist AI su testo libero (anti-BOLA, `Member::TicketsController#analyze`/`#compose`)
- `R422-TICKET-001` — creazione ticket fallita (validazione corpo strutturato, `Ticketing::CreateTicket`)
- `R422-TICKET-002` — aggiornamento ticket fallito (validazione, `Ticketing::UpdateTicket`)
- `R422-TICKET-003` — transizione di stato non valida (`Ticketing::ChangeStatus`)
- `R422-TICKET-004` — milestone non valida (non appartenente al progetto, `Ticketing::ChangeMilestone`)
- `R422-TICKET-005` — domanda vuota al RAG "chiedi ai ticket" (`Ticketing::AskTickets`)
- `R422-TICKET-006` — decisione di review su un ticket non in review (`Ticketing::RejectReview`/`ApproveReview`)
- `R422-TICKET-007` — rifiuto review senza motivo (`Ticketing::RejectReview`)
- `R422-TICKET-008` — nessuno status di destinazione attivo per la decisione di review (`Ticketing::RejectReview`/`ApproveReview`) o per la fase da proiettare (`Agents::Workflows::StatusProjection`, CYRA-622)
- `R404-TICKET-003` — ticket da collegare non trovato nello scope del gate duplicati (anti-BOLA, `Ticketing::ResolveDuplicate`)
- `R404-TICKET-004` — nessuno snapshot del contesto di lavoro (ticket mai preso in carico; audit CYRA-76, `Cli::V1::Tickets::WorkContextController`)
- `R422-TICKET-009` — "crea comunque" senza motivazione nel gate duplicati (`Ticketing::ResolveDuplicate`)
- `R422-TICKET-010` — tipo di collegamento non valido nel gate duplicati (`Ticketing::ResolveDuplicate`)
- `R422-TICKET-011` — esito del confronto duplicati sconosciuto (`Ticketing::ResolveDuplicate`)
- `R422-TICKET-012` — testo vuoto per la composizione AI del ticket / AI Buddy (`Ticketing::ComposeTicket`, `Member::TicketsController#compose`)
- `R422-TICKET-013` — dipendenza tra ticket che chiuderebbe un ciclo (`Connections::TicketDependency` validazione `no_cycle` + rivalutazione sotto lock; sollevato al create sia dalla CLI sia da `Ticketing::AddDependency` nell'area Member, CYRA-80/82)
- `R422-TICKET-014` — cambio stato bloccato da prerequisiti aperti: ingresso in category in_progress/done con blocker non ancora done (`Ticketing::DependencyGuard`, invocato da `Ticketing::ChangeStatus`/`ApproveReview`/`Agents::Workflows::ApproveAutopilot`; ricontrollo sotto lock nella stessa transazione, CYRA-81)
- `R403-TICKET-001` — prerequisito aggiunto o tolto da un'utenza che non è una persona (`account.service?`, o attore assente): `Ticketing::AddDependency`/`RemoveDependency` rifiutano PRIMA di leggere il dato, così la risposta non dipende da cosa esiste sul ticket e non rivela quali prerequisiti ci sono. Il discriminante è l'attore, non il canale: operatore e host usano lo stesso canale CLI e lo stesso tipo di token. Blindato anche sul model (`Connections::TicketDependency`, validazione `on: :create`), che è il punto che nessun canale aggira. Nel disegno nuovo i prerequisiti sono l'unica cosa che tiene in piedi l'ordine deciso da chi approva il piano (CYRA-596)
- `R404-TICKET-015` — blocker non trovato/non visibile nell'aggiunta di una dipendenza (anti-BOLA, `Ticketing::AddDependency`, CYRA-82)
- `R404-TICKET-016` — dipendenza non trovata nella rimozione: risalita attraverso il ticket visibile corrente (anti-BOLA + idempotenza della seconda rimozione, `Ticketing::RemoveDependency`, CYRA-82)
- `R422-TICKET-017` — aggiunta dipendenza fallita per validazione non-ciclo: auto-dipendenza, cross-organizzazione o prerequisito già associato (`Ticketing::AddDependency`, CYRA-82)
- `R422-TICKET-018` — motivo di un respingimento oltre `Ticketing::Constants::REVIEW_REASON_MAX_CHARS`, cioè oltre il tetto del resoconto in cui la motivazione lunga viene salvata (`Ticketing::RejectReview`, CYRA-389)
- `R422-TICKET-019` — "Crea e collega" senza nessun ticket spuntato sulla pagina di confronto (`Ticketing::ResolveDuplicate`, CYRA-633). Distinto da `R404-TICKET-003`, che vale per un id che non esiste o non è visibile: qui non è stato scelto niente, e la risposta deve dirlo.
- `R409-TICKET-020` — stato di un ticket la cui lavorazione automatica è avviata e non conclusa: la leva ha un padrone solo (`Ticketing::ChangeStatus`, CYRA-609). Bloccato sempre da CLI e webhook; dal web passa solo se chi lo sposta è una persona che ha preso in carico il ticket. Il `019` del piano era già occupato da `R422-TICKET-019`: la numerazione è progressiva sul dominio, non per prefisso.
- `R403-TICKET-021` — approvazione del lavoro consegnato firmata da un'utenza che non è una persona, o da un attore assente (`Ticketing::ApproveReview`, CYRA-611). È la SECONDA fermata umana: il permesso `tickets.edit` non basta a distinguere, perché ce l'ha anche il service account dell'host, che lo usa per portare il ticket in revisione quando consegna. Gemello di `R403-WORKFLOW-001`, che chiude allo stesso modo la prima fermata (il piano). Il `R403-TICKET-001` che il piano proponeva era già occupato dai prerequisiti (CYRA-596): la numerazione è progressiva sul dominio, non per prefisso. Il discriminante è l'ATTORE, non il canale né lo stato della lavorazione — rifiutare «a lavorazione in corso» bloccherebbe l'operatore, perché quel comando È la fermata
- `R409-ATTEMPT-006` — lavoro dichiarato «già consegnato» e riletto sul solo resoconto, ma nessun tentativo precedente della stessa lavorazione aveva fatto rileggere sul diff quel commit (`Agents::Attempts::DeliveryContract`, CYRA-1004). Senza questo controllo, un codice la cui rilettura era fallita tornava al giro dopo come «già consegnato» e andava avanti senza che nessuno lo avesse letto
- `R409-ATTEMPT-005` — rilascio consegnato con un numero di versione (o un punto di codice) diverso da quello che il server aveva assegnato prima che la fase partisse (`Agents::Attempts::Deliver`, CYRA-621). Il numero non è un'etichetta qualsiasi: è il nome con cui una versione viene chiamata per sempre. Vale solo sui rami che hanno davvero pubblicato: uno stato che non rilascia niente non ha un numero da confrontare
- `R409-WORKFLOW-008` — non è stato possibile leggere le versioni già uscite sul deposito, quindi non si sa da dove partire per calcolare la prossima (`Agents::Releases::NextVersion`, CYRA-621). Inventarne una rischierebbe di riusare un nome già pubblicato
- `R409-WORKFLOW-009` — il numero calcolato è stato assegnato a un'altra lavorazione nel frattempo, due volte di fila (`Agents::Releases::Assign`, CYRA-621). La corsa la perde il database invece di GitHub a pubblicazione avvenuta
- `R409-WORKFLOW-010` — la versione definitiva non ha un punto di codice verificato da pubblicare (`Agents::Releases::Assign`, CYRA-621): senza, si pubblicherebbe «da qualche parte»
- `R409-WORKFLOW-011` — il progetto non dichiara come si prova che un rilascio è vivo (`Agents::Probes::Bind`, CYRA-624): la lavorazione si ferma subito invece di aspettare un'ora per una prova che nessuno andrà mai a guardare
- `R409-WORKFLOW-012` — manca la credenziale di sola lettura per il registro delle immagini (`Agents::Probes::Bind`, CYRA-625): la prova non si arma e chiama subito una persona, invece di aspettare un'ora in silenzio
- `R409-WORKFLOW-013` — su un ticket già concluso non si decide, da nessuna parte (`Agents::Workflows::ConcludedTicketGate`, CYRA-630): la guardia vive nei service, così nessuna pagina può aggirarla
- `R409-WORKFLOW-015` — «Ferma» su una lavorazione che non sta aspettando la produzione (`Agents::Workflows::HoldProduction`, CYRA-871)
- `R422-REGISTRY-001` — nome del pacchetto o versione fuori dall'alfabeto della loro famiglia (`Agents::Registries::Client`, CYRA-625): si rifiuta PRIMA che parta qualunque chiamata, perché un nome che è a sua volta un indirizzo cambierebbe lo scaffale interrogato
- `R502-REGISTRY-001` — il registro pubblico non ha risposto o ha risposto con un errore suo (CYRA-625): linea storta, si riprova
- `R502-REGISTRY-002` — il registro ha risposto con un corpo che non si legge (CYRA-625): è una linea storta, non una negazione
- `R502-REGISTRY-003` — il registro ha risposto «troppe richieste» (CYRA-625): si riprova più in là
- `R409-WORKFLOW-005` — il codice della proposta è cambiato dopo il controllo, e l'approvazione arriva su un codice diverso da quello mostrato (`Agents::Workflows::ApproveAutopilot`, CYRA-617). Non è un errore di chi approva: la lavorazione esce dalla pila delle decisioni, il verbale si azzera e ne nasce uno nuovo da controllare. In produzione non va niente.
- `R409-WORKFLOW-006` — non è stato possibile leggere lo stato vivo della proposta al momento dell'approvazione (`Agents::Workflows::ApproveAutopilot`, CYRA-617). Distinto da `005` di proposito: «non ho potuto guardare» non è «il codice è cambiato». Niente si azzera, la lavorazione non risulta ferma, e si riprova.
- `R409-WORKFLOW-007` — la proposta di modifica non esiste più (cancellata o chiusa) al momento dell'approvazione (`Agents::Workflows::ApproveAutopilot`, CYRA-617). Risposta definitiva: non si rimette nessuna riga da controllare, perché non c'è niente da guardare.

### COMMENT — commenti ai ticket (`Ticketing::AddComment`, CLI `Cli::V1::Tickets::CommentsController`)
- `R422-COMMENT-001` — creazione commento fallita (validazione: corpo vuoto/non valido)

### IDEA — idee di progetto (service `Ideas::*`, condivisi da area Member e CLI `Cli::V1::Ideas*`)
- `R404-IDEA-001` — progetto dell'idea non visibile/inesistente nello scope (anti-BOLA, `Ideas::CreateIdea`)
- `R422-IDEA-001` — creazione/aggiornamento idea fallito (validazione, `Ideas::{CreateIdea,UpdateIdea}`)
- `R422-IDEA-002` — idea non aperta: congelata da conversione/archiviazione o transizione non valida (`Ideas::{UpdateIdea,AddComment,DeleteComment,AddCase,UpdateCase,DeleteCase,ChangeStatus,PromoteToTicket}`)
- `R422-IDEA-003` — idea già convertita in ticket (`Ideas::{ChangeStatus,PromoteToTicket}`)
- `R422-IDEA-004` — commento all'idea non valido (`Ideas::AddComment`)
- `R422-IDEA-005` — case dell'idea non valido (`Ideas::{AddCase,UpdateCase}`)
- `R404-IDEA-002` — idea di base (`evolves_id`) o idea da collegare non trovata nel progetto (anti-BOLA, `Ideas::{CreateIdea,LinkIdeas}`)
- `R422-IDEA-006` — collegamento fra idee non valido: stessa idea, progetti diversi, coppia già collegata, evoluzione a più livelli (`Ideas::{CreateIdea,LinkIdeas}`)

### KNOWLEDGE — knowledge base (pagine N:N su progetti/gruppi, service `Knowledge::*`, condivisi da area Member e CLI `Cli::V1::Knowledge::*`)
- `R403-KNOWLEDGE-001` — pagina "generale" org-wide (zero progetti/gruppi) creata o aggiornata da chi non ha accesso pieno (`Knowledge::CreatePage`/`Knowledge::UpdatePage`)
- `R403-KNOWLEDGE-002` — collegamento di una pagina NON propria a un progetto/gruppo (anche vuoto) su cui manca `knowledge.edit` (`Knowledge::UpdatePage`)
- `R403-KNOWLEDGE-003` — publish che convergerebbe (sovrascrivendola) su una pagina non gestibile dall'attore, es. collegata solo a progetti non visibili (`Knowledge::Pages::Publish`)
- `R403-KNOWLEDGE-004` — decisione sulla revisione (accettare/scartare/segnare come scritta su file) chiesta da chi non può gestire la pagina (`Knowledge::Pages::ReviewGuards`)
- `R403-KNOWLEDGE-005` — accettare o scartare una proposta chiesto da un account NON umano (`kind: :service`, o attore assente): la revisione è un gesto di una persona, il permesso da solo non basta (`Knowledge::Pages::{Approve,Reject}` via `ReviewGuards`)
- `R404-KNOWLEDGE-001` — progetto/gruppo della pagina non visibile/inesistente nello scope (anti-BOLA, `Knowledge::CreatePage`/`Knowledge::UpdatePage`)
- `R404-KNOWLEDGE-002` — progetto del book non visibile/inesistente nello scope (anti-BOLA, `Knowledge::Books::Save`)
- `R409-KNOWLEDGE-001` — publish ambiguo: più pagine legacy hanno lo stesso titolo (`Knowledge::Pages::Publish`)
- `R422-KNOWLEDGE-001` — creazione pagina fallita (validazione, `Knowledge::CreatePage`)
- `R422-KNOWLEDGE-002` — aggiornamento pagina fallito (validazione, `Knowledge::UpdatePage`)
- `R422-KNOWLEDGE-003` — domanda vuota al RAG "chiedi alla KB" (`Knowledge::AskPages`)
- `R422-KNOWLEDGE-004` — salvataggio book fallito (validazione, `Knowledge::Books::Save`)
- `R422-KNOWLEDGE-005` — publish pagina fallito (publication_key o contenuto non validi, `Knowledge::Pages::Publish`)
- `R422-KNOWLEDGE-006` — pagina di un progetto non incluso nel book, non aggiungibile al TOC (`Knowledge::Books::AddPage`)
- `R422-KNOWLEDGE-007` — pagina già associata a un altro book, non spostabile via add-page (`Knowledge::Books::AddPage`)
- `R422-KNOWLEDGE-008` — upload allegato fallito (nessun file, tipo MIME fuori allowlist — sniffato sui byte reali, non dichiarato — o dimensione oltre il limite, `Knowledge::Attachments::Upload`)
- `R422-KNOWLEDGE-009` — transizione di revisione chiesta da uno stato che non la ammette (accettare una pagina già decisa, consolidarne una ancora in revisione; `Knowledge::Pages::ReviewGuards`)
- `R422-KNOWLEDGE-010` — consolidamento senza percorso del documento (`Knowledge::Pages::MarkConsolidated`)
- `R422-KNOWLEDGE-011` — filtro `?status=` non riconosciuto nell'elenco pagine CLI (`Cli::V1::Knowledge::PagesController`)
- `R422-KNOWLEDGE-012` — proposta in revisione con corpo tecnico e senza parte tecnica: servono i due livelli (`Knowledge::CreatePage`, CYRA-429)
- `R422-KNOWLEDGE-013` — il revisore automatico ha rifiutato la pagina: fuori formato o con una regola violata (`Knowledge::ReviewPage`, CYRA-764). `details.violations[]` porta `code`+`message`, `details.format` il formato riconosciuto; il `message` elenca le prime violazioni perché la CLI stampa solo quello
- `R422-KNOWLEDGE-014` — pacchetto di contesto chiesto senza dire di quale progetto (`Cli::V1::Knowledge::PagesController#context`, CYRA-767): il contesto è per progetto, e "di tutto" è già l'elenco pagine
- `R502-KNOWLEDGE-001` — il revisore ha risposto con un verdetto illeggibile (fuori enum o forma): la pagina NON entra (`Knowledge::Review::Parse`)
- `R503-KNOWLEDGE-001` — revisore non disponibile (server AI di casa giù, tempo scaduto, chiave rifiutata o `CHAT_*` non configurati): fail-closed, la pagina NON entra. `details.cause` porta il codice `R*-CHAT-*` di trasporto. Il freno è l'interruttore `knowledge_review` in Valhalla

### PRODUCT — matrice funzionalità × piattaforme (`Product::*`, area Member `Member::Product::*`)
- `R404-PRODUCT-001` — stato o versione non ammissibili per questa cella (id fuori dagli stati attivi dell'org o dalle release del prodotto che girano su quella piattaforma; anti-BOLA, `Product::Cells::Set`)
- `R422-PRODUCT-001` — salvataggio categoria fallito (nome blank o già usato nel prodotto, `Product::Categories::Save`)
- `R422-PRODUCT-002` — salvataggio funzionalità fallito (nome blank o duplicato nella categoria, pagina KB non visibile, `Product::Features::Save`)
- `R422-PRODUCT-003` — salvataggio cella fallito (validazione: stato disattivato, release non coerente con prodotto e piattaforma, `Product::Cells::Set`)
- `R422-PRODUCT-004` — categoria non eliminabile: contiene ancora funzionalità (`Product::Categories::Destroy`)

### ATTACHMENT — allegati ai ticket (`Ticketing::AttachToTicket`, condiviso Member + CLI `Cli::V1::Tickets::AttachmentsController`)
- `R422-ATTACHMENT-001` — allegato non valido (nessun file, tipo MIME non ammesso — sniffato sui byte reali, o dimensione oltre il limite)

### MONITOR — uptime monitoring (`Uptime::Monitors::Save`, condiviso Member + CLI `Cli::V1::MonitorsController`)
- `R422-MONITOR-001` — create/update monitor fallito (validazione: url blank/non valido, environment non dichiarato dal progetto, duplicato `[progetto, environment]`, interval/timeout/expected_status fuori range)

### UPTIME — incident narrati (grouping + timeline) e banner status page (`Uptime::Incidents::*`, `Uptime::Announcements::Save`)
- `R422-UPTIME-001` — raggruppamento incident invalido (nessun incident valido, o id non top-level/di un altro monitor — anti-BOLA; `Uptime::Incidents::GroupAndUpdate`)
- `R422-UPTIME-002` — step timeline invalido (phase non ammessa; `Uptime::Incidents::GroupAndUpdate`/`AddUpdate`)
- `R422-UPTIME-003` — banner status page invalido (messaggio blank o finestra ends_at ≤ starts_at; `Uptime::Announcements::Save`)
- `R422-UPTIMEGROUP-001` — create/update gruppo uptime fallito (validazione: name blank; canale CLI `Cli::V1::UptimeGroupsController`)

### CRON — heartbeat monitoring (`Crons::RecordCheckIn`, `Api::V1::CronCheckInsController`)
- `R422-CRON-001` — check-in invalido (slug mancante o parametri monitor non validi)

### RELEASE — release tracking (`Api::V1::ReleasesController`)
- `R422-RELEASE-001` — version mancante nel POST della release
- `R422-RELEASE-002` — version mancante nella segnalazione di un rilascio non in piedi (`POST …/deploy_failures`, CYRA-871)
- `R409-RELEASE-001` — il progetto non ha un CTO effettivo a cui assegnare il ticket del rilascio non in piedi (`Projects::Releases::ReportDeployFailure`, CYRA-871)

### ALERT — regole di alerting (`Alerting::Rules::Save`, condiviso Member + CLI `Cli::V1::AlertRulesController`)
- `R422-ALERT-001` — create/update regola fallito (validazione: name blank, event_type non ammesso, project/environment di un'altra org — anti-BOLA)
- `R422-ALERT-002` — webhook URL non sicura a delivery-time (guard anti-SSRF, `Notifications::Deliver::Webhook`)
- `R422-ALERT-003` — update preferenze di alert personali fallito (validazione, canale CLI `Cli::V1::AlertPreferencesController`)
- `R502-ALERT-001` — webhook irraggiungibile o HTTP non-2xx (fire-and-forget, loggato)
- `R502-ALERT-002` — Telegram irraggiungibile o HTTP non-200 (fire-and-forget, loggato)

### MILESTONE — milestone di progetto (`Projects::Milestone`, CRUD inline condiviso Member + CLI `Cli::V1::MilestonesController`)
- `R422-MILESTONE-001` — create/update milestone fallito (validazione: code/label/color blank, code duplicato per progetto)

### DOCUMENT — documenti di progetto (`Projects::Documents::Upload`, area Member)
- `R422-DOCUMENT-001` — upload fallito (nessun file selezionato, oppure tipo/dimensione fuori allowlist — sniff Marcel sui byte reali)

### SECRET — vault di variabili d'ambiente cifrate per-progetto/ambiente (`Secrets::Variables::*`, condiviso Member + CLI `Cli::V1::Projects::SecretsController`)
- `R422-SECRET-001` — set/import variabile fallito (validazione: nome fuori formato `[A-Z_][A-Z0-9_]*`, prefisso riservato `GITHUB_`, ambiente non dichiarato dal progetto, duplicato `[progetto, ambiente, nome]`)
- `R422-SECRET-002` — eliminazione variabile fallita
- `R422-SECRET-003` — rollback a una versione che non appartiene al secret (`Secrets::Variables::Rollback`)
- `R422-SECRET-004` — richiesta di approvazione (`Secrets::ChangeRequest`) invalida su una coppia protetta, es. nome fuori formato inviato dalla riga-crea della matrice (`Secrets::ChangeRequests::Submit`, CYRA-138)
- `R403-SECRET-001` — environment non consentito all'account (restrizione env di un service account; `Cli::V1::Projects::SecretsController`)

### CHANGEREQUEST — richieste di modifica ai secret su ambienti protetti (approvazione a due/4-eyes, `Secrets::ChangeRequests::*`, CYRA-138 Fase 4)
- `R422-CHANGEREQUEST-001` — rifiuto senza motivo, obbligatorio (`Secrets::ChangeRequests::Reject`)
- `R403-CHANGEREQUEST-001` — vincolo 4-eyes: chi decide (approva/rifiuta) non può essere chi ha presentato la richiesta (`Secrets::ChangeRequests::{Approve,Reject}`)
- `R403-CHANGEREQUEST-002` — solo il richiedente può ritirare la propria richiesta (`Secrets::ChangeRequests::Cancel`)
- `R403-CHANGEREQUEST-003` — vincolo umano (CYRA-640): la decisione la prende una PERSONA, un account di servizio (`Accounts::Account` kind `service`) non può approvare né rifiutare, nemmeno se diverso dal richiedente e con `secrets.manage` (`Secrets::ChangeRequests::{Approve,Reject}`; è il PRIMO guard, precede stale/4-eyes/motivo — non vale per `Cancel`, ritirare la propria richiesta non scavalca nulla)
- `R409-CHANGEREQUEST-001` — la richiesta non è più `pending` (già applicata/rifiutata/ritirata): non ridecidibile, guard idempotenza/stale sotto lock (`Secrets::ChangeRequests::{Approve,Reject,Cancel}`)
- (nota: l'applicazione di una richiesta approvata chiama direttamente `Secrets::Variables::{Set,Delete}` — un errore di validazione lì propaga il MEDESIMO codice del service delegato, es. `R422-SECRET-001`, senza marcare la richiesta come applicata)

### PERSONALSECRET — vault PERSONALE per-utente (`Secrets::Personal::Variables::*`, scope `[account, organization]`, condiviso Member + CLI `Cli::V1::PersonalSecretsController`)
- `R422-PERSONALSECRET-001` — set/import variabile fallito (validazione: nome fuori formato `[A-Z_][A-Z0-9_]*`, duplicato `[account, organizzazione, nome]`)
- `R422-PERSONALSECRET-002` — eliminazione variabile fallita
- `R422-PERSONALSECRET-003` — rollback a una versione che non appartiene al secret (`Secrets::Personal::Variables::Rollback`)

### SECRETFILE — file sensibili cifrati e versionati (`Secrets::Assets::*`)
- `R422-SECRETFILE-001` — estensione non ammessa (`.p8`, `.p12`, `.jks`, `.keystore`, service-account `.json`)
- `R422-SECRETFILE-002` — file vuoto o superiore a 10 MiB
- `R422-SECRETFILE-003` — contenuto non coerente col formato dichiarato
- `R422-SECRETFILE-004` — validazione o salvataggio dell'asset fallito
- `R422-SECRETFILE-005` — autenticazione AES-GCM fallita: ciphertext, tag, chiave o metadati manomessi
- `R422-SECRETFILE-006` — environment opzionale non dichiarato dal progetto
- `R422-SECRETFILE-007` — purge richiesto prima dell'archiviazione

### PERSONALSECRETFILE — file segreti PERSONALI per-utente (`Secrets::Personal::Assets::*`, scope `[account, organization]`, condiviso Member + CLI `Cli::V1::PersonalSecretAssetsController`)
- `R422-PERSONALSECRETFILE-001` — file mancante nell'upload
- `R422-PERSONALSECRETFILE-002` — file vuoto o superiore a 10 MiB
- `R422-PERSONALSECRETFILE-004` — validazione o salvataggio del file fallito
- `R422-PERSONALSECRETFILE-005` — autenticazione AES-GCM fallita: ciphertext, tag, chiave o metadati manomessi
- `R422-PERSONALSECRETFILE-007` — cancellazione definitiva richiesta prima dell'archiviazione (numerazione allineata a `R422-SECRETFILE-007`, stesso guardrail)

### SHARED — vault CONDIVISO org-level di variabili (`Secrets::Shared::{Save,Delete}`, condiviso Member `Member::SharedSecretsController` + CLI `Cli::V1::SharedSecretsController`)
- `R422-SHARED-001` — save fallito (validazione: nome fuori formato `[A-Z_][A-Z0-9_]*`, prefisso riservato `GITHUB_`, duplicato per organizzazione) oppure, solo canale CLI, environment assente/inesistente nell'organizzazione
- `R409-SHARED-001` — conferma d'impatto obsoleta o mancante: rotazione/eliminazione di un valore già delegato a un progetto richiede il digest ricalcolato dell'impatto (`Secrets::Shared::Impact`); il canale CLI bypassa il banner umano (azione singola: `skip_confirmation` in `Save`, digest ricalcolato internamente in `destroy`)

### CONSOLIDATION — «valore in comune»: lo stesso valore ripetuto in più progetti, spostato nei secret dell'organizzazione (`Secrets::Consolidation::Promote`, canale Member `Member::Vault::ConsolidationsController`)
- `R409-CONSOLIDATION-001` — conferma d'impatto obsoleta o mancante: fra la pagina e il clic è cambiato chi tiene quel valore (un terzo progetto l'ha preso, uno l'ha cambiato). Il digest è quello di `Secrets::Consolidation::Impact` e copre lo STATO (progetti, variabili, valore già nell'organizzazione), non le scelte di chi conferma — il nome e gli alias possono cambiare fino all'ultimo senza invalidare la conferma
- `R422-CONSOLIDATION-001` — una scrittura della transazione è stata rifiutata da una validazione: la delega non può nascere (secret disabilitati su quell'ambiente per un progetto, collisione di nome effettivo). Nulla è stato spostato: o si sposta tutto, o non si sposta niente
- `R422-CONSOLIDATION-002` — non c'è più niente da spostare (il valore non è più ripetuto in due o più progetti), oppure il secret dell'organizzazione non si è potuto scrivere col nome scelto (nome fuori formato, già preso). `details` porta gli errori del secret quando è quel caso

### SAVEDVIEW — viste salvate delle index filtrabili (`SavedViews::Save`, area Member)
- `R422-SAVEDVIEW-001` — salvataggio vista fallito (validazione: nome vuoto o duplicato per account+organizzazione+risorsa)

### TODOLIST — liste di todo personali per-org (`Todos::Lists::Save`, condiviso Member + CLI `Cli::V1::TodoListsController`)
- `R422-TODOLIST-001` — salvataggio lista fallito (validazione: nome vuoto o duplicato per account+organizzazione)

### TODOITEM — voci di una lista di todo (`Todos::Items::{Save,Toggle}`, condiviso Member + CLI `Cli::V1::TodoLists::ItemsController`)
- `R422-TODOITEM-001` — salvataggio voce fallito (validazione: titolo vuoto, o ticket linkato di un'altra organizzazione — anti-leak tenant)

### TODOSHARE — condivisione in lettura di una lista (`Todos::Shares::SetShares`, condiviso Member + CLI `Cli::V1::TodoLists::SharingController`)
- `R422-TODOSHARE-001` — condivisione fallita (destinatario non membro dell'organizzazione della lista, o il proprietario stesso)

### CHAT — chat tra membri (`Chat::Conversations::*`, `Chat::PostMessage`, controller FLAT `Member::Chat*Controller`)
Solo la chat fra persone: dal CYRA-766 il trasporto verso il modello generativo non usa più questo dominio (vedi LLM).
- `R422-CHAT-001` — DM con sé stessi (`FindOrCreateDirect`)
- `R422-CHAT-002` — uno dei due account non è membro dell'organizzazione (`FindOrCreateDirect`)
- `R403-CHAT-003` — nessun progetto in comune: si può scrivere solo a chi condivide un progetto (`FindOrCreateDirect`)
- `R422-CHAT-004` — creazione DM fallita (validazione, `FindOrCreateDirect`)
- `R422-CHAT-005` — contesto non valido per un canale (né progetto né team, `FindOrCreateChannel`)
- `R403-CHAT-006` — canale non accessibile: l'actor non vede il contesto (`FindOrCreateChannel`)
- `R422-CHAT-007` — creazione canale fallita (validazione, `FindOrCreateChannel`)
- `R422-CHAT-010` — invio messaggio fallito (validazione: corpo vuoto senza allegati, `PostMessage`)
- `R409-CHAT-011` — notifica già consegnata: dedup_key duplicata (`Notifications::Deliver::{InApp,Email}`)

### AI — dominio (triage on-demand: `Errors::TriageWithAi`, `Errors::FindSimilarGroups`, `Metrics::TriageWithAi`, `Ticketing::AnalyzeBugReport`, `Ticketing::ComposeTicket`)
Dal CYRA-765 il trasporto verso il fornitore emette codici `R50x-LLM-00x` (vedi `Ai::Llm::Client`), che i service rigirano invariati in `AppError`. Qui restano i codici del dominio AI, quelli che nascono da noi e non dal fornitore.
- `R502-AI-003` — output AI illeggibile: la risposta non ha la forma attesa (es. non è un oggetto)
- `R502-AI-004` — la bozza del ticket non è arrivata in fondo nemmeno al secondo giro (`Ticketing::ComposeTicket`)
- `R502-AI-005` — risposta del servizio embeddings/rerank malformata o di dimensione inattesa (`Ai::Embedding::Client`, `Embeddings::EmbedText`)
- `R502-AI-006` — config AI mancante per il RAG della KB (KeyError su ENV, `Knowledge::AskPages`)
- `R422-AI-008` — l'indirizzo del provider AI scritto da un'organizzazione porta dentro la rete interna (`Ai::ProviderHttp`, CYRA-914): nessuna chiamata parte
- `R422-AI-007` — allegato testuale non UTF-8 nel vaglio agenti: nessuna chiamata AI o sostituzione dei byte (`Ticketing::EvaluateAgentEligibility`)
- `R502-AI-007` — output AI illeggibile nel RAG della KB (`Knowledge::AskPages`)
- `R404-AI-001` — richiesta AI asincrona non trovata o scaduta (`Member::Ai::RequestsController#show`, ownership anti-BOLA)
- `R422-AI-001` — kind di richiesta AI sconosciuto (`Ai::RunJob`, difensivo)
- `R422-AI-002` — testo da embeddare vuoto (`Embeddings::EmbedText`; guardato a monte dai chiamanti UI)
- `R503-AI-001` — servizio AI spento dal god in Valhalla (`Ai::Feature`). 503 e non 502: l'upstream sta bene, il rubinetto l'abbiamo chiuso noi
- `R503-AI-002` — rerank non configurato: `EMBED_RERANK_MODEL` assente (`Ai::Embedding::Client#rerank`). I chiamanti degradano all'ordine coseno; non è un guasto, è una scelta di deploy (CYRA-758)

### LLM — modello generativo del server AI di casa (`Ai::Llm::Client`, LiteLLM su DGX, CYRA-765 + CYRA-766)
Codici emessi dall'**unico** client verso il proxy (trasporto OpenAI-compatible `POST /chat/completions`: streaming SSE per il testo, sincrono per gli attrezzi) e mappati in `AppError` dal service/job. Fornitore di sistema, alias `vlm-fast`: nessuna chiave portata dall'organizzazione. Due coppie di ENV per lo stesso proxy, scelte dal profilo `credentials:` — `AI_BASE_URL`/`AI_API_KEY` (di sistema) e `CHAT_BASE_URL`/`AI_API_KEY` (revisore knowledge), distinte perché si spengono separatamente.

Dal CYRA-766 **non esiste più la famiglia `*-CHAT-*` del trasporto AI**: quei codici erano gli stessi guasti con un altro nome, e collidevano per numero con la chat fra membri (`R403-CHAT-003` era «nessun progetto in comune» e `R400-CHAT-003` «alias sconosciuto»). Chi ne trova uno in un log vecchio: `R401-CHAT-001`/`R403-CHAT-001` → `R502-LLM-002`, `R400-CHAT-003` → `R502-LLM-003`, `R429-CHAT-001` → `R429-LLM-001`, `R503-CHAT-002` → `R503-LLM-001`, `R502-CHAT-002`/`R504-CHAT-002`(HTTP)/`R5xx-CHAT-003` → `R502-LLM-001`, `R502-CHAT-001` (rete) → `R502-LLM-001`, `R502-CHAT-004`/`-005`/`-006` → gli stessi numeri con `LLM` al posto di `CHAT`, `R504-CHAT-001` → `R504-LLM-001`, `R504-CHAT-002` (tetto totale) → `R504-LLM-002`.

- `R502-LLM-001` — errore upstream del fornitore (HTTP ≥400 diverso da auth/rate limit/503) o errore di rete (reset, TLS, DNS)
- `R502-LLM-002` — auth fallita (401/403: chiave rifiutata dal proxy) **o** config mancante (chiave non in env → KeyError, mai 500): definitivo, nessun ritentativo
- `R502-LLM-003` — richiesta rifiutata (HTTP 400: schema, payload o alias del modello non validi — `Invalid model name`, che il proxy dà come 400 e non come 404): definitivo
- `R502-LLM-004` — il modello non ha prodotto testo (filtro, o solo `tool_calls` dove non attesi): risposta non prodotta, non guasto
- `R502-LLM-005` — structured output non parsabile come JSON
- `R502-LLM-006` — la risposta non è arrivata in fondo: `finish_reason: "length"`. Distinto da -005 perché «non ha scritto JSON» e «non è arrivato in fondo» si correggono in due modi diversi (CYRA-639)
- `R502-LLM-007` — il CORPO della risposta HTTP non è JSON: guasto del trasporto, non del modello (solo la modalità sincrona con attrezzi)
- `R429-LLM-001` — troppe richieste al fornitore (HTTP 429)
- `R402-LLM-001` / `R402-AI-001` — la chiave CloseYourIt AI ha raggiunto il tetto mensile (HTTP 402 dal gateway, CYRA-920)
- `R402-AI-002` — l'organizzazione ha speso il suo tetto mensile di token AI (`Ai::TokenBudget`, CYRA-914): nessuna chiamata parte fino al mese dopo o a un tetto più alto
- `R503-LLM-001` — server AI non disponibile (HTTP 503). Nessuna riserva su un secondo modello: i chiamanti degradano
- `R504-LLM-001` — timeout HTTP verso il fornitore: apertura, o attesa fra un pezzo e l'altro dello stream
- `R504-LLM-002` — tetto TOTALE della chiamata (`deadline_seconds`) superato: lo stream era vivo ma troppo lento. Il read timeout non lo vedrebbe mai, perché misura le pause, non la durata

### ASSISTANT — assistente help conversazionale (`Assistant::*`, controller FLAT `Member::Assistant*Controller`)
- `R422-ASSISTANT-001` — messaggio vuoto (l'utente non ha scritto nulla, `Assistant::PostMessage` e `Assistant::Converse`)
- `R422-ASSISTANT-002` — tetto dei giri di attrezzi raggiunto (`Assistant::Converse::MAX_TURNS`): il modello ha continuato a chiedere attrezzi senza arrivare a una risposta. Esito, non guasto: si dice a chi ha scritto che non ci siamo riusciti
- `R422-ASSISTANT-003` — contesto oltre `Assistant::Converse::MAX_CONTEXT_CHARS`: gli attrezzi hanno restituito troppo perché la conversazione prosegua a un costo sensato. Distinto dal 002 perché si cura diversamente (attrezzi troppo generosi, non modello confuso)
- `R422-ASSISTANT-004` — domanda oltre `Assistant::Constants::MAX_MESSAGE_CHARS` sul canale CLI (`Cli::V1::Assistant::Conversations::MessagesController`). Sul web lo stesso tetto TRONCA in silenzio (`Assistant::PostMessage`), perché chi scrive vede il proprio testo; un client JSON no, e riceverebbe la risposta a una domanda tagliata senza modo di accorgersene
- `R500-ASSISTANT-001` — guasto imprevisto mentre si componeva la risposta (`Assistant::ConverseJob`): la risposta viene marcata fallita invece di restare "in lavorazione" per sempre, poi l'eccezione risale per il retry

> Il 404 anti-BOLA (conversazione di un altro utente) NON ha un codice dedicato: `Assistant::Conversation.for(...).find` solleva `ActiveRecord::RecordNotFound`, mappato globalmente al 404 di sistema come gli altri controller member. Vale anche per la separazione fra i due assistenti (`kind`): una conversazione nata nel sito, chiesta dal canale CLI, è un 404 e non un 403.

### SERVER — server monitoring (`Api::V1::Servers::SamplesController`, `Servers::*`)
- `R401-SERVER-001` — enrollment token mancante o non valido (anche revocato)
- `R401-SERVER-002` — credenziale per-host revocata (CYRA-245): distinto dal 001 perché si cura diversamente — la sonda non ha un codice sbagliato, ha un codice che NON VALE PIÙ e deve ripartire dall'enrollment token. Col 401 unico l'agent ripresentava all'infinito una credenziale morta e la macchina spariva dal monitoraggio
- `R403-SERVER-002` — host revocato (l'agent deve fermarsi)
- `R422-SERVER-001` — fingerprint mancante nel push
- `R413-SERVER-002` — payload oltre `Servers::Constants::MAX_PAYLOAD_BYTES`
- `R422-SERVER-003` — emissione enrollment token fallita (validazione)
- `R422-SERVER-004` — payload malformato (body non parsabile)
- `R422-SERVER-005` — rename host fallito (validazione: name blank; `Cli::V1::ServersController#update`)
- `R422-SERVER-006` — link server↔environment fallito (progetto non uptime-capable, environment non dichiarato, host revocato o di altra org, duplicato; `Servers::Links::Attach`)

### TELEGRAM — bot ufficiale (webhook inbound `Telegram::WebhooksController` + comandi `Telegram::*` + trasporto `Telegram::Send`)
- `R404-TELEGRAM-001` — token del deep-link /start invalido o scaduto (`Telegram::LinkAccount`; il webhook risponde comunque 200, niente retry)
- `R502-TELEGRAM-001` — Telegram irraggiungibile o HTTP non-200 in uscita (`Telegram::Send`, fire-and-forget, loggato)
- `R502-TELEGRAM-002` — bot non configurato: `TELEGRAM_BOT_TOKEN` assente (`Telegram::Send` / `Telegram::DownloadFile`)
- `R502-TELEGRAM-003` — chat_id destinatario mancante (`Telegram::Send`)
- `R502-TELEGRAM-004` — download di un file (foto/documento) fallito: getFile/binario non-200 o rete giù (`Telegram::DownloadFile`; il ticket/commento è comunque creato senza allegato)
- `R404-TELEGRAM-002` — chiave progetto sconosciuta tra i progetti visibili (`Telegram::ResolveProject`, comando /progetto o /nuovo-ticket)
- `R404-TELEGRAM-003` — nessun progetto attivo (o non più visibile) per l'account (`Telegram::ResolveProject`, /nuovo-ticket senza chiave)
- `R404-TELEGRAM-005` — ticket non trovato tra i visibili per il code CHIAVE-NUMERO (`Telegram::ResolveTicket`, /ticket o /commenta)
- `R409-TELEGRAM-001` — chiave progetto ambigua: stessa chiave visibile in più organizzazioni (`Telegram::ResolveProject`)
- `R422-TELEGRAM-006` — file_id mancante nel download (`Telegram::DownloadFile`)
- `R422-TELEGRAM-007` — codice ticket mancante o malformato (atteso CHIAVE-NUMERO; `Telegram::ResolveTicket` / `Telegram::ShowTicket`)
- `R422-TELEGRAM-008` — chiave progetto mancante nel comando /progetto (`Telegram::SetActiveProject`)
- `R422-TELEGRAM-009` — testo del ticket mancante nel comando /nuovo-ticket (`Telegram::CreateTicketFromMessage`)
- `R502-TELEGRAM-010` — Telegram ha letto e rifiutato il messaggio (HTTP 400: testo troppo lungo, HTML non leggibile…; l'argomento salvato resta)
- `R502-TELEGRAM-011` — argomento del gruppo non creato: gruppo senza argomenti o bot senza permesso (`Telegram::CreateForumTopic`; l'avviso va nel generale del gruppo)
- `R403-TELEGRAM-012` — chi ha aggiunto il bot al gruppo non è più il proprietario dell'organizzazione (`Telegram::LinkGroup`)
- `R422-TELEGRAM-013` — il gruppo non ha gli argomenti attivi (`Telegram::LinkGroup`; il bot lo spiega nel gruppo)
- `R502-TELEGRAM-014` — l'argomento del gruppo non esiste più (HTTP 400 `message thread not found`: `Telegram::SendToGroup` ne apre uno nuovo e riprova una volta, CYRA-874)
- `R422-TELEGRAM-010` — testo del commento mancante nel comando /commenta (`Telegram::AddCommentFromMessage`)

### WORKLOAD — carico di lavoro non-dev team-scoped (`Workload::Actions::*`, condiviso Member + CLI `Cli::V1::Workload::*`)
- `R422-WORKLOAD-001` — salvataggio action fallito (validazione: titolo vuoto, ticket di altra org; `Save`)
- `R422-WORKLOAD-002` — aggiornamento partecipanti fallito (validazione; `SetParticipants`)
- `R422-WORKLOAD-003` — action già collegata a un ticket (idempotenza; `PromoteToTicket`)
- `R404-WORKLOAD-001` — progetto target non visibile al reporter (`PromoteToTicket`, anti-BOLA)

### HOMEDEFERRAL — rimandi della home a domani (`Home::Deferrals::Defer`, canale Member)
- `R422-HOMEDEFERRAL-001` — salvataggio del rimando fallito (validazione: chiave o scadenza mancante)
- `R422-HOMEDEFERRAL-002` — nessuna decisione indicata da rimandare (chiave vuota)

### DATASET — dataset AI (`Datasets::*`, area Member)
- `R422-DATASET-001` — salvataggio dataset/colonne fallito (validazione: nome/label vuoti, code duplicato o non valido, category senza valori, due colonne result; `Datasets::Save`)
- `R404-DATASET-001` — progetto non trovato o non gestibile dall'attore (`Datasets::Save`, anti-BOLA via VisibleScope)
- `R422-DATASET-003` — salvataggio riga fallito (validazione: required mancante, immagine non ammessa; `Datasets::Rows::Save`)
- `R422-DATASET-004` — training non avviabile (righe sample insufficienti o nessun target; `Datasets::Trainings::Run`)
- `R422-DATASET-005` — predizione senza un training completato (`Datasets::Predictions::Predict`)
- `R500-DATASET-001` — addestramento interrotto: il processo che lo eseguiva è morto senza esito (SIGKILL, deploy interrotto, worker riavviato) e nessun segno di vita è arrivato per oltre `Datasets::Constants::TRAINING_STALE_AFTER` (`Datasets::Trainings::MarkStale`, CYRA-791). Esito recuperabile: un nuovo avvio riparte, niente viene rilanciato da solo
- `R409-DATASET-001` — addestramento non avviabile: un altro è già pending/running sullo stesso dataset (`Datasets::Trainings::Start`, guardia atomica sotto lock — il doppio avvio è doppio costo AI)
- `R502-DATASET-001` — storico: era «LLM non disponibile durante build/predict». Dal CYRA-548 quel caso è `R503-INTEGRATION-006` (servizio non collegato) oppure un codice `R50x-AI-00x` propagato dal gateway. Resta scritto sui training e sulle previsioni fallite prima di allora.
- `R502-DATASET-002` — risposta LLM illeggibile durante build/predict (`Datasets::Ai::{BuildPrompt,Predict}`, `Datasets::Predictions::Predict`)

### AGENT — Agent Host e coda (`Agents::*`, canali Member + `Api::V1::Agents*`/`agent_host` automator)
- `R401-AGENT-001` — token automator mancante/non valido o autorità errata: cyi_a_ solo bootstrap,
  cyi_ah_ solo pull/report (anche host/token revocati; `AutomatorAuthentication`)
- `R422-AGENT-003` — emissione token automator fallita (validazione; `Agents::Tokens::Issue`)
- `R422-AGENT-004` — registrazione o telemetria host automator fallita, inclusa una piattaforma diversa da Linux (payload/validazione; `Agents::Hosts::*`)
- `R422-AGENT-005` — runtime non valido nella richiesta di policy dei limiti (`Api::V1::LimitsController`)
- `R409-AGENT-001` — idempotency key reservation riutilizzata con parametri diversi
- `R409-AGENT-002` — pin dello skill bundle rifiutato: la `version` è più vecchia di quella già pinnata (monotonico anti-downgrade; `force: true` per un rollback intenzionale; `Agents::SkillBundles::Pin`)
- `R409-AGENT-003` — registrazione host rifiutata: il fingerprint è già legato a un ALTRO service account (un host = una macchina = un service account; `Agents::Hosts::Register`)
- `R409-AGENT-004` — registrazione host rifiutata: il service account è già legato a un ALTRO host (relazione 1-1 host↔service account, indice unico `service_account_id`; `Agents::Hosts::Register`)
- `R404-AGENT-009` — nessuna versione delle skill cyi disponibile per l'organizzazione: elenco vuoto o tutte ritirate (`Agents::SkillReleases::Resolve`)
- `R422-AGENT-010` — versione delle skill da fissare inesistente o ritirata (`Agents::SkillReleases::Pin`)
- `R502-AGENT-001` — release pubbliche delle skill cyi non leggibili: GitHub o il mirror non rispondono o rispondono male; l'elenco resta com'era (`Agents::SkillReleases::Sync`)
- `R403-AGENT-001` — host automator revocato: la stessa identità non può ri-registrarsi
- `R403-AGENT-002` — registrazione host negata: solo un service account (`account.service?`) può registrare un host, non una sessione utente umana (`Api::V1::HostsController`)
- `R403-AGENT-007` — chiamata host-bound negata: l'host storico non usa Linux (`AutomatorAuthentication`, `Agents::Hosts::RecordHeartbeat`)
- `R404-AGENT-002` — progetto/repository non trovato nell'organizzazione del token host (anti-BOLA; `Api::V1::LimitsController`)
- `R404-AGENT-003` — host heartbeat non trovato, revocato o legato a un altro progetto ingest (anti-BOLA)
- `R404-AGENT-004` — nessuno skill bundle pinnato per l'organizzazione (host resta in prompt-mode; `Agents::Hosts::SkillManifest`)
- `R404-AGENT-005` — l'organizzazione non ha una credenziale Claude per le macchine: l'host usa il proprio login (`Agents::Hosts::LentCredential`)
- `R403-AGENT-003` — credenziale Claude negata: l'host non è certificato (`Agents::Hosts::LentCredential`)
- `R404-AGENT-006` — l'organizzazione non ha una chiave OpenRouter per le macchine: nessuna macchina rilegge con OpenCode (`Agents::Hosts::LentCredential`)
- `R403-AGENT-008` — chiave OpenRouter negata: l'host non è certificato (`Agents::Hosts::LentCredential`)
- `R403-AGENT-009` — token GitHub negato: l'host non tiene un lease attivo sul ticket (`Agents::Hosts::GithubToken`)
- `R403-AGENT-010` — token GitHub negato: l'host non è certificato (`Agents::Hosts::GithubToken`)
- `R404-AGENT-007` — token GitHub: ticket non trovato fra i progetti visibili all'host (anti-BOLA; `Agents::Hosts::GithubToken`)
- `R404-AGENT-008` — token GitHub: il progetto del ticket non ha un repository GitHub collegato (`Agents::Hosts::GithubToken`)
- `R422-AGENT-006` — pin dello skill bundle fallito (validazione repo/ref/version/digest; `Agents::SkillBundles::Pin`)
- `R422-AGENT-007` — certificazione host fallita (validazione; `Agents::Hosts::Certify`)

### ATTEMPT — consegna del risultato di una fase (`Agents::Attempts::*`, canale `Api::V1` `agent_attempts`)
- `R404-ATTEMPT-001` — tentativo, lease o scope non più validi alla consegna: host diverso da quello del
  tentativo, lease scaduto o di un altro run, fase/impronta del profilo non più corrispondenti, host non
  più eleggibile (`Agents::Attempts::Deliver#lock_scope!`, rivalidato sotto lock)
- `R409-ATTEMPT-001` — gemello del precedente sul canale HTTP: la consegna arriva su un tentativo che non è
  più consegnabile (409, l'host non deve ritentare identico)
- `R409-ATTEMPT-002` — consegna già registrata con un payload DIVERSO: il replay idempotente vale solo a
  parità di `delivery_digest` (`Deliver#replay_result`)
- `R409-ATTEMPT-003` — revisione incrociata mancante o non approvata: runtime/reviewer non coerenti col
  tentativo, oppure `review.status` diverso da `accepted` (`Deliver#validate_delivery`)
- `R422-ATTEMPT-001` — risultato strutturato non valido: fuori dallo schema `agent-result/v1` della fase,
  codice ticket di un altro ticket (anti cross-ticket), o domande di chiarimento non semplici
  (`Agents::Clarification`: massimo 3, ≤180 caratteri, senza comandi/path/URL)

Gli stati terminali di un tentativo sono `approved`, `review_failed`, `rejected`, `failed`, `stale`,
`cancelled`. `stale` è assegnato dal controllo periodico `Agents::MarkStaleAttemptsJob` a una lavorazione
la cui prenotazione è scaduta senza consegna; `cancelled` solo da un'azione umana con motivazione
(`Agents::Workflows::Cancel`). Un tentativo terminale è audit immutabile: `Attempt#ensure_mutable` rifiuta
ogni aggiornamento successivo, e un claim che vi ricadesse riceve `R409-QUEUE-001`.

### QUEUE — selezione e claim della coda ticket Automator (`Agents::TicketQueues::*`)
- `R404-QUEUE-001` — selezione firmata riferita a un altro tenant/agente o agente queue non più attivo
- `R409-QUEUE-001` — selezione firmata stale: candidato, target, repository o stato non più eleggibile
  (incluso un tentativo della stessa lavorazione già chiuso come terminale)
- `R409-QUEUE-002` — claim negato da un limite server-side (kill switch, runtime, parallelismo o budget)
- `R409-QUEUE-003` — claim escluso da un defer attivo per lo stesso agente (include reason/retry_at)
- `R409-QUEUE-004` — defer rifiutato perché un lease attivo ha già reclamato il ticket
- `R409-QUEUE-005` — TTL del claim diverso dal `timeout_seconds` autoritativo dell'agente
- `R409-QUEUE-007` — il rilascio in produzione aspetta il freno (`Agents::Workflows::ProductionHold`, CYRA-871): 2 ore di prova dello staging, poi nessun errore nuovo aperto in staging. Il motivo è nei details (`staging_soak` con `until`, oppure `staging_errors` con `error_group_id`)
- `R422-QUEUE-001` — selezione firmata mancante, malformata, alterata o scaduta
- `R422-QUEUE-002` — claim senza una stima server-side mentre è attivo `max_daily_cost`
- `R422-QUEUE-003` — ragione di defer assente o fuori dalla policy server-side
- `R403-QUEUE-001` — `host_id` del defer diverso dall'Agent Host autenticato

### LEASE — mutua esclusione ticket fra titolari (`Agents::Leases::*`, canali `Api::V1::Leases::*` per gli Agent Host e `Cli::V1::Tickets::LeasesController` per gli account)
- `R403-LEASE-001` — `host_id` del payload diverso dall'Agent Host autenticato
- `R403-LEASE-002` — account autenticato non appartenente all'organizzazione del ticket
- `R404-LEASE-001` — ticket inesistente o di un'altra organizzazione (anti-BOLA)
- `R404-LEASE-002` — lease mai acquisito o scaduto (renew/release senza tombstone nota)
- `R409-LEASE-001` — lease attivo detenuto da un altro host o run
- `R409-LEASE-002` — acquire ritardato di una lavorazione già rilasciata (nessun holder riutilizzabile)
- `R409-LEASE-003` — renew con TTL diverso dal TTL autoritativo fissato dal claim queue
- `R409-LEASE-004` — scadenza autoritativa del claim trascorsa prima dell'acquisizione del lease
- `R409-LEASE-005` — renew host-first su un lease il cui profilo di fase pinnato è cambiato (drift del PhaseProfile)
- `R409-LEASE-006` — acquire dello stesso run su un lease attivo già pinnato per un'altra execution_phase
- `R422-LEASE-001` — payload lease non valido (ticket/path, run/agent fino a 255 caratteri, TTL da 1 secondo a 30 giorni, o `host_id` dichiarato sul canale account — lì il titolare viene dal token)
- `R503-LEASE-001` — stato lease modificato ripetutamente durante acquire; il client può riprovare

### GITHUB — integrazione GitHub App (repo↔progetto 1:1, binding tag→release, branch/PR↔ticket)
- `R502-GITHUB-001` — errore/timeout API GitHub (`Github::Client::Error`; installation token, ref, create_ref, create_pull)
- `R422-GITHUB-001` — connessione repo fallita (validazione; `Github::Repositories::Connect`)
- `R404-GITHUB-002` — progetto senza repo GitHub agganciato (azione branch/PR richiede un repo)
- `R409-GITHUB-003` — repo già agganciato a un altro progetto (vincolo 1:1)
- `R404-GITHUB-004` — installazione GitHub App assente per l'org (connettere prima l'App)
- `R422-GITHUB-005` — creazione branch/PR fallita (`Ticketing::Github::{CreateBranch,OpenPullRequest}`)
- `R422-GITHUB-006` — push sync dei secret non eseguibile (`sync_secrets` off, installazione assente; `Secrets::Github::Sync`). Gli errori di trasporto GitHub restano `R502-GITHUB-001`.
- `R422-GITHUB-007` — configurazione del bundle virtuale `SECRETS_JSON` invalida o con sorgenti mancanti (`Secrets::Github::Preflight` tramite `Secrets::Github::SecretsJson`); il sync manuale lo restituisce prima di accodare il job.
- `R422-GITHUB-008` — bundle virtuale `SECRETS_JSON` oltre il limite GitHub di 48 KB (`Secrets::Github::SecretsJson`).
- `R404-GITHUB-010` — GitHub ha guardato e ha detto di no: risorsa assente o non accessibile (404/410, e 403 senza segnali di limite). È una **negazione autorevole**, opposta a `R502-GITHUB-001`, che dice «non ho potuto guardare» (timeout, 5xx, 429, 403 con `retry-after` o quota esaurita). Chi legge deve trattarli in modo opposto: sul primo serve una persona, sul secondo si aspetta e si riprova. Confonderli fa chiamare qualcuno a ogni singhiozzo di rete, oppure tacere quando la risorsa davvero non c'è (`Github::Client#handle`, CYRA-599).
- `R422-GITHUB-012` — il bundle `SECRETS_JSON` non è stato costruito e non si sa perché: i due file `.kamal` non si leggono, e l'albero del ramo o non risponde, o è troncato, oppure li elenca (`Secrets::Github::SecretsJson`, CYRA-652). Prima quel caso tornava `Result.ok(nil)`, cioè «questo repository il bundle non lo usa»: nessun bundle scritto, sincronizzazione dichiarata riuscita e il conto pagato mesi dopo dal rilascio, che si ferma con la cassetta vuota. `details[:unreadable]` porta i path coinvolti.
- `R422-GITHUB-011` — il sync si ferma perché il progetto ha un ambiente (`Types::Environment#code` = `production`/`staging`/`preview`) che il repository non mappa, o perché non ne mappa nessuno (`Secrets::Github::Preflight`, CYRA-637). Prima quegli slot venivano scartati in silenzio: il sync scriveva sui rimanenti, chiamava `record_sync_success!` e la storia mostrava una riga verde su metà lavoro. `details[:unmapped]` porta i nomi degli ambienti non collegati (vuoto quando non ce n'è nessuno).
- `R422-GITHUB-009` — il sync del vault ha trovato una variabile/sorgente senza plaintext (`nil`) e fallisce chiuso senza scrivere nulla (`Secrets::Github::Preflight`, `Secrets::Github::SecretsJson`). Una stringa vuota passata esplicitamente resta valida e viene serializzata come `""`, mai come `null`; il guard evita la conversione `null` → stringa `"null"` che ha corrotto la master key dei file segreti (CYRA-213).

### INTEGRATION — credenziali dei servizi esterni portate dall'organizzazione (`Integrations::Verify`, CYRA-544)
- `R422-INTEGRATION-001` — la chiave è rifiutata dal fornitore: scaduta, revocata, inesistente o bloccata dalle sue restrizioni. Si ricopia. Google la dichiara con una ragione strutturata che inizia per `API_KEY_` (`error.details[].reason`), mai col messaggio.
- `R422-INTEGRATION-002` — la chiave va bene ma quel servizio non è acceso sull'account del fornitore (`SERVICE_DISABLED`, `SERVICE_NOT_ACTIVATED`, `ACCESS_TOKEN_SCOPE_INSUFFICIENT`). Si accende nella sua console: ricopiare la chiave non serve a niente.
- `R422-INTEGRATION-005` — la chiave è valida ma le sue **restrizioni** non la lasciano passare (`API_KEY_*_BLOCKED`: servizio, referrer HTTP, indirizzo IP, app Android/iOS). Si allargano le restrizioni della chiave — è un terzo posto ancora, diverso sia dal ricopiare sia dall'accendere il servizio.
- `R504-INTEGRATION-003` — il fornitore non si raggiunge (timeout, socket, TLS, connessione chiusa a metà). Si riprova: non dice niente sulla chiave.
- `R502-INTEGRATION-004` — risposta del fornitore che non sappiamo classificare, servizio sconosciuto al registro, o guasto a monte. È il ripiego, mai un «va tutto bene» travestito.
- `R503-INTEGRATION-006` — l'organizzazione non ha collegato quel servizio, quindi la funzione non parte (`Integrations::Providers.not_connected_error`, CYRA-548). 503 e non 502: il fornitore sta benissimo, manca il collegamento da questa parte. Chi lo emette non chiama niente e non scrive niente — il vaglio dei ticket, per esempio, lascia il ticket `pending`, cioè fuori dalla coda degli agenti.

> L'esito viaggia anche come slug in `details[:outcome]` (`invalid_key`, `service_disabled`,
> `key_restricted`, `unreachable`, `upstream_error`): è quel valore che finisce in `integrations_credentials.verification_error`
> ed è la chiave i18n del messaggio mostrato. **Mai il testo libero del fornitore**, che può contenere
> pezzi della richiesta — e quindi la chiave in chiaro dentro una colonna di testo.

### SERVICEACCOUNT — account di servizio (membri AI, CLI-only) — `Accounts::Service::*`, canale Member
- `R422-SERVICEACCOUNT-001` — creazione service account fallita (validazione: nome vuoto, handle duplicato, o step di accesso fallito; `Accounts::Service::Create`)
- `R422-SERVICEACCOUNT-002` — retire (elimina audit-safe) del service account fallito (`Accounts::Service::Retire`)

### SYSTEM — generici / framework
Resi da `ErrorRendering`, incluso via `ApiEnvelope` da entrambe le basi dei canali macchina
(`Api::BaseController`, `Cli::Api::BaseController`): sono le eccezioni che il framework solleva prima
che il codice di dominio possa dire la sua, e senza una resa qui finivano sull'`exceptions_app`, cioè
su una PAGINA HTML servita a un client che si aspetta JSON (CYRA-718). Un `rescue_from` registrato in
un controller figlio continua ad avere la precedenza: è così che l'ingest conserva i propri codici.
- `R404-SYSTEM-001` — risorsa non trovata (`ActiveRecord::RecordNotFound`). È anche la risposta
  anti-BOLA: un id di un'altra organizzazione arriva qui esattamente come un id inesistente, stesso
  codice e stesso messaggio, perché la differenza confermerebbe che quel dato esiste.
- `R422-SYSTEM-001` — validazione fallita (`ActiveRecord::RecordInvalid`); `details` è `errors.to_hash`,
  campo → messaggi, la stessa forma dei 422 di dominio che gestiscono la validazione sul posto
- `R422-SYSTEM-002` — parametro mancante (`ActionController::ParameterMissing`); `details.param` porta il nome
- `R400-SYSTEM-001` — corpo della richiesta non leggibile (`ActionDispatch::Http::Parameters::ParseError`):
  il JSON non si apre, quindi non c'è nessun parametro da validare
