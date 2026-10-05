# frozen_string_literal: true

module Authorization
  # Catalogo STATICO delle chiavi-permesso (per-azione). Ogni chiave = un gate nel codice, quindi
  # NON è CRUD: aggiungerne una richiede codice (discriminatore statico, vedi rules/lookup-tables.md).
  # I RUOLI (Authorization::Role, dinamici) raggruppano queste chiavi; gli override personali
  # (Authorization::AccountPermission) le attivano/disattivano. Read = visibilità di scope, NON una
  # chiave. Aprire un ticket / commentare = baseline di chi vede lo scope (non gated qui).
  #
  # `scoped: true` → permesso per-progetto (richiede uno scope visibile nel Resolver).
  # `scoped: false` → permesso org-level (nessuno scope progetto).
  module Catalog
    ENTRIES = [
      # --- Scoped (per progetto) -------------------------------------------------------------
      { key: "tickets.edit",               area: "tickets",    scoped: true },
      { key: "tickets.assign",             area: "tickets",    scoped: true },
      { key: "tickets.delete",             area: "tickets",    scoped: true, dangerous: true },
      { key: "tickets.comment.delete_any", area: "tickets",    scoped: true, dangerous: true },
      { key: "tickets.attachments.manage", area: "tickets",    scoped: true },
      # Audit della presa in carico (CYRA-76): leggere lo snapshot immutabile della Guidance consegnata
      # al claim. Chiave SEPARATA e non baseline "read = visibilità di scope" (deroga come secrets.read/
      # secrets_audit.view): è materiale d'audit su chi/quando/cosa è stato consegnato a un agente, non
      # contenuto ordinario del ticket. Per-progetto: lo snapshot appartiene a un ticket del progetto.
      { key: "tickets.audit.view",         area: "tickets",    scoped: true },
      # Ideas: aprire/votare/commentare = baseline di chi vede lo scope (non gated). L'AUTORE
      # gestisce sempre la propria idea aperta (edit/archive/delete/convert); le chiavi gatano
      # le stesse azioni sulle idee ALTRUI.
      { key: "ideas.edit",                 area: "ideas",      scoped: true },
      { key: "ideas.delete",               area: "ideas",      scoped: true, dangerous: true },
      { key: "ideas.convert",              area: "ideas",      scoped: true },
      { key: "ideas.comment.delete_any",   area: "ideas",      scoped: true, dangerous: true },
      # Help desk (CYRA-940): reading is gated too, unlike the other lists. A request carries the
      # address of a visitor, a person outside the organization: seeing the project is not enough.
      { key: "helpdesk.manage",            area: "helpdesk",   scoped: true },
      { key: "errors.triage",              area: "monitoring", scoped: true },
      { key: "errors.promote",             area: "monitoring", scoped: true },
      # CYRA-192 — chiave SEPARATA da errors.triage di proposito: fondere ed eliminare distruggono
      # dati e non si annullano, mentre il triage sposta uno stato e si torna indietro. Il ruolo
      # "Triager" nasce per smistare, non per cancellare: appendere queste azioni a errors.triage
      # avrebbe allargato in silenzio i privilegi di chi quel ruolo ce l'ha già.
      { key: "errors.destroy",             area: "monitoring", scoped: true, dangerous: true },
      # CYRA-153 — assegnare un errore a una persona. Chiave PROPRIA, non errors.triage: assegnare è
      # dare in carico (reversibile, non distruttivo), un asse diverso dallo smistare uno stato. Sta
      # nel ruolo Triager insieme a triage/promote (chi smista è chi mette in mano l'errore).
      { key: "errors.assign",              area: "monitoring", scoped: true },
      # CYRA-153 — regole di raggruppamento personalizzate del progetto (configurazione dell'ingest,
      # non triage né distruzione): chiave di gestione a sé, nel ruolo Maintainer.
      { key: "errors.grouping.manage",     area: "monitoring", scoped: true },
      { key: "artifacts.manage",           area: "monitoring", scoped: true, dangerous: true },
      { key: "metrics.promote",            area: "monitoring", scoped: true },
      { key: "logs.link",                  area: "monitoring", scoped: true },
      { key: "uptime.manage",              area: "monitoring", scoped: true },
      # CYRA-506 — decidere cosa fare di una vulnerabilità trovata: ignorarla (convivo col rischio),
      # riaprirla, promuoverla a ticket. La LETTURA non è una chiave: la governa la visibilità del
      # progetto, come per errori e log.
      { key: "vulnerabilities.triage",     area: "monitoring", scoped: true },
      # CYRA-528 — il cockpit SEO ha le stesse due chiavi delle vulnerabilità, per la stessa ragione:
      # dichiarare un sito da visitare è configurazione (chi lo fa decide cosa il sistema andrà a
      # bussare, e quanto spesso), decidere cosa fare di un rilievo è triage. La LETTURA non è una
      # chiave: la governa la visibilità del progetto, come per errori, log e vulnerabilità.
      { key: "seo.manage",                 area: "monitoring", scoped: true },
      { key: "seo.triage",                 area: "monitoring", scoped: true },
      # CYRA-697 — pubblicare la dashboard di traffico su internet è l'unica azione dell'area che porta
      # dati fuori dal perimetro dell'organizzazione, quindi `dangerous`. La LETTURA della dashboard
      # resta senza chiave, come per errori e log: la governa la visibilità del progetto.
      { key: "analytics.share.manage",     area: "monitoring", scoped: true, dangerous: true },
      { key: "tokens.manage",              area: "projects",   scoped: true, dangerous: true },
      # Provision blind: può depositare SOLO una credenziale generata dal server; non concede lettura
      # né scrittura di valori scelti dal client e resta separato da secrets.manage.
      { key: "secrets.provision",          area: "projects",   scoped: true },
      # Secret del vault (variabili d'ambiente cifrate per-progetto/ambiente). read = leggere i VALORI
      # (deroga al principio "read = visibilità di scope": i valori sono sensibili → gate esplicito);
      # manage = set/delete/import. Consumati da Member web e Cli::V1 (cyi secrets/run).
      # CYRA-721 — le due chiavi sono INDIPENDENTI: manage NON implica read. Chi gestisce può cambiare un
      # valore senza vederlo (la matrice e la lista dal terminale gli mostrano i soli nomi), chi legge lo
      # vede senza poterlo cambiare. Un ruolo che deve fare entrambe le cose porta entrambe le chiavi.
      { key: "secrets.read",               area: "projects",   scoped: true, dangerous: true },
      { key: "secrets.manage",             area: "projects",   scoped: true, dangerous: true },
      { key: "secret_files.read",          area: "projects",   scoped: true, dangerous: true },
      { key: "secret_files.manage",        area: "projects",   scoped: true, dangerous: true },
      # Integrazione GitHub del progetto: agganciare/scollegare il repo, regole di binding tag→release,
      # creazione branch/PR dai ticket. Per-progetto (l'installazione org-level è gated organization.manage).
      { key: "github.manage",              area: "projects",   scoped: true },
      { key: "projects.edit",              area: "projects",   scoped: true },
      { key: "projects.delete",            area: "projects",   scoped: true, dangerous: true },
      # Documenti di progetto: lettura = visibilità di scope (nessuna chiave .view, principio sopra);
      # upload/rinomina/eliminazione gated qui.
      { key: "documents.manage",           area: "projects",   scoped: true },
      # Knowledge base: leggere/creare = baseline di chi vede lo scope; l'AUTORE gestisce sempre
      # le proprie pagine — le chiavi gatano edit/delete sulle pagine ALTRUI (pattern Ideas).
      { key: "knowledge.edit",             area: "knowledge",  scoped: true },
      { key: "knowledge.delete",           area: "knowledge",  scoped: true, dangerous: true },
      # Moderazione del canale chat di un progetto (eliminare messaggi altrui). L'autore può sempre
      # eliminare i propri; nei DM/canali-team non c'è moderazione (solo l'autore).
      { key: "chat.moderate",              area: "chat",       scoped: true, dangerous: true },
      # Datasets (sezione AI): lettura = visibilità del progetto (nessuna chiave .view). manage =
      # creare/modificare dataset, colonne, righe. train = lanciare training + predizioni (costa LLM).
      { key: "datasets.manage",            area: "datasets",   scoped: true },
      { key: "datasets.train",             area: "datasets",   scoped: true, dangerous: true },
      # --- Org-level (senza scope progetto) --------------------------------------------------
      # Per le pagine org-level: `*.view` gata la LETTURA (index/show), `*.manage` la gestione.
      # Pattern manage-implies-view nei gate (vedi PermissionGates#can_view_*?).
      { key: "projects.create",            area: "projects",   scoped: false },
      { key: "project_groups.view",        area: "projects",   scoped: false },
      { key: "project_groups.manage",      area: "projects",   scoped: false },
      { key: "platforms.view",             area: "settings",   scoped: false },
      { key: "platforms.manage",           area: "settings",   scoped: false },
      { key: "environments.view",          area: "settings",   scoped: false },
      { key: "environments.manage",        area: "settings",   scoped: false },
      { key: "members.view",               area: "people",     scoped: false },
      { key: "members.manage",             area: "people",     scoped: false, dangerous: true },
      { key: "members.edit",               area: "people",     scoped: false },
      { key: "members.invite",             area: "people",     scoped: false },
      { key: "permissions.manage",         area: "people",     scoped: false, dangerous: true },
      { key: "organization.manage",        area: "settings",   scoped: false, dangerous: true },
      # The organization's own AI provider, models, keys and token cap (CYRA-914).
      { key: "ai.manage",                  area: "settings",   scoped: false, dangerous: true },
      { key: "shared_secrets.manage",      area: "settings",   scoped: false, dangerous: true },
      { key: "shared_secret_files.manage", area: "settings",   scoped: false, dangerous: true },
      # Audit del Vault (CYRA-135): pagina org-level di sola LETTURA degli eventi sui secret (chi legge/
      # modifica/sincronizza variabili e file). view = accedere alla pagina Attivita del Vault.
      { key: "secrets_audit.view",         area: "settings",   scoped: false },
      # Registro attività (CYRA-745): la pagina org-level di sola LETTURA che risponde a «chi ha fatto
      # cosa e quando» unendo i registri di lavoro, ticket, permessi e Vault. Chiave PROPRIA e non
      # secrets_audit.view: quel permesso parla dei soli segreti, questa pagina parla di tutto il resto.
      # I due si SOMMANO — le righe del Vault entrano solo per chi ha anche secrets_audit.view, così la
      # pagina non diventa la scorciatoia per leggere l'audit dei segreti senza averne il permesso.
      { key: "activity.view",              area: "settings",   scoped: false },
      { key: "alerts.manage",              area: "monitoring", scoped: false },
      # Server monitoring: gli host sono org-level (nessuno scope progetto). view = fleet + show;
      # manage = rename/pause/revoke/destroy + enrollment token.
      { key: "servers.view",               area: "monitoring", scoped: false },
      { key: "servers.manage",             area: "monitoring", scoped: false, dangerous: true },
      { key: "servers.execute",            area: "monitoring", scoped: false, dangerous: true },
      # Gruppi di monitor uptime: contenitori ORG-LEVEL (aggregano monitor di progetti diversi).
      # view = pagina gruppi + dashboard CRUD; manage = create/edit/delete + publish status page.
      { key: "uptime_groups.view",         area: "monitoring", scoped: false },
      { key: "uptime_groups.manage",       area: "monitoring", scoped: false, dangerous: true },
      # Agenti automation: definizioni org-level (assegnate a progetti/gruppi) eseguite dal daemon
      # closeyourit-automator. view = lista + storico run; manage = CRUD + assegnazione + token.
      { key: "agents.view",                area: "automation", scoped: false },
      { key: "agents.manage",              area: "automation", scoped: false, dangerous: true },
      # Matrice funzionalità × piattaforme (CYRA-256): la matrice appartiene a un Projects::Group.
      # ORG-LEVEL per forza: il Resolver accetta come scope solo un Projects::Project (#scope_visible?
      # e #covers? leggono project.group_id), un gruppo darebbe sempre false. La riservatezza resta
      # garantita dal linkage — i controller risolvono dentro visible.groups, come per
      # project_groups.view/manage. view = leggere le matrici; manage = categorie, funzionalità, celle.
      { key: "product_features.view",      area: "product",    scoped: false },
      { key: "product_features.manage",    area: "product",    scoped: false }
    ].freeze

    BY_KEY = ENTRIES.index_by { |e| e[:key] }.freeze

    class << self
      def all = ENTRIES

      def keys = BY_KEY.keys

      def valid?(key) = BY_KEY.key?(key)

      def entry(key) = BY_KEY[key]

      # Per-progetto? Chiave sconosciuta → false (il Resolver la nega comunque).
      def scoped?(key) = BY_KEY.dig(key, :scoped) || false

      # Raggruppa le voci per area, preservando l'ordine di dichiarazione (per la UI dei ruoli).
      def by_area = ENTRIES.group_by { |e| e[:area] }

      # Le aree dichiarate, nell'ordine del catalogo. Ognuna è un titolo di gruppo nella pagina dei
      # permessi: senza nome tradotto la pagina mostra il segnaposto di i18n (CYRA-574).
      def areas = by_area.keys

      # CYRA-439 — concederlo distrugge dati, apre informazioni riservate, esegue comandi o allarga
      # i privilegi. Chiave sconosciuta → false: nel dubbio non si segnala un permesso che non c'è.
      def dangerous?(key) = BY_KEY.dig(key, :dangerous) || false

      # Le aree toccate da un insieme di chiavi, nell'ordine di dichiarazione del catalogo: è quello
      # che l'elenco dei ruoli mostra al posto di «22 chiavi», che non diceva niente a nessuno.
      def areas_for(keys)
        wanted = Array(keys).to_set
        ENTRIES.filter_map { |entry| entry[:area] if wanted.include?(entry[:key]) }.uniq
      end
    end
  end
end
