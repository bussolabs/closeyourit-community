# frozen_string_literal: true

module Agents
  # Fonte UNICA del profilo di esecuzione di ogni fase del flusso agenti. Nel modello host-first è la
  # FASE (execution_phase) — non un agente tipizzato — a determinare runtime, sandbox, permessi, tool
  # ammessi e ttl. Costante dev-defined (eccezione enum-static di rules/lookup-tables.md), non tabella.
  # Rimpiazza la fonte oggi sparsa: Command::RUNTIMES + Command#write_access? + Agents::Save#runtime_profile.
  # PIVOT CYAU-87: la parità con quella fonte legacy resta PARZIALE per tutte le fasi — condividono
  # sandbox/allowed_tools/write_access? ma runtime e permission_mode DIVERGONO: host-first esegue con Claude
  # headless (`bypassPermissions`, perché in headless non esiste un approvatore e ogni altra modalità nega gli
  # script delle skill) mentre la fonte legacy resta Codex/nil finché il sistema typed-agent non viene rimosso
  # (CYAU-85). Codex resta solo cross-reviewer. La spec (spec/models/agents/phase_profile_spec.rb) fissa il
  # confine: la differenza READ↔WRITE è la SANDBOX, non il permission_mode.
  #
  # VOCABOLARIO CANONICO — tre tipi distinti, da non confondere:
  #   - execution_phase : le 5 fasi eseguibili qui elencate. Questa costante È il vocabolario canonico:
  #                       dopo MT-9 non esiste più un enum del catalogo con cui tenersi allineati.
  #   - skill_key       : la skill del bundle invocata, /closeyourit-<fase con trattini>.
  #   - workflow_state  : lo stato FSM del ticket, DERIVATO dai timestamp di Agents::Workflow
  #                       (triage_requested_at, triaged_at, approved_at, ...). La readiness — "quale fase
  #                       è pronta per un ticket" — vive in Agents::TicketQueues::Next, NON qui.
  #
  # Il profilo sceglie SOLO valori server-ammessi (dentro Agent::PERMISSION_MODES/SANDBOX_MODES e i tool
  # read-only) e non indebolisce mai la command-policy né i guardrail runtime, che restano autoritativi a
  # valle. Le costanti sono deep-frozen: allowed_tools NON è mutabile a runtime (garanzia di sicurezza).
  #
  # SICUREZZA delle fasi WRITE (permission_mode "bypassPermissions"): NON è una scelta di comodità e la
  # sicurezza NON è affidata al permission_mode di Claude. L'esecuzione è headless (`claude -p`), dove
  # "default"/"acceptEdits" si bloccherebbero su prompt che nessun umano approva → bypassPermissions è
  # l'unico mode che consente la write autonoma. La rete di sicurezza vera è a VALLE, imposta dall'automator
  # a OGNI sessione (mai una sessione non guardata): guardrail PreToolUse obbligatori e hash-verificati
  # (block-production, block-destructive-db, require-worktree = Edit/Write SOLO nel worktree gestito,
  # guard-branch-push = push SOLO ticket/*) + command-policy runtime-agnostica pre-spawn, il tutto
  # fail-closed. La sandbox workspace-write confina inoltre le scritture al worktree isolato del ticket, con
  # review umana via PR prima di ogni merge. closer_production non deploya (kamal bloccato): tagga soltanto,
  # e parte da sola appena la prova dello staging è chiusa (closer_staging_verified_at): il via libera umano
  # dedicato di CYRA-504 è stato tolto con CYRA-629. Nessun GitHub Environment ha regole di protezione:
  # dopo il tag non c'è nessun altro controllo umano, quindi l'ultimo è l'approvazione del lavoro consegnato.
  class PhaseProfile
    # ttl = tetto di esecuzione della fase, in secondi. In PARITÀ con gli agenti tipizzati creati da
    # RebuildAuthorizedAgents (db/migrate/20260715085246_rebuild_authorized_agents.rb: `timeout_seconds`
    # è hardcoded a 3600 per triage/planner/autopilot), NON col default DB generico (300, per agenti
    # shell/altri). I closer, mai creati come agenti, ereditano lo stesso tetto delle altre fasi.
    # Nel modello host-first il ttl passa da per-agente (Agent#timeout_seconds) a per-fase.
    DEFAULT_TTL_SECONDS = 3600

    # Whitelist read-only delle fasi READ (triage/planner). Le fasi WRITE non usano whitelist: la scrittura
    # è governata dalla sandbox workspace-write.
    READ_ONLY_TOOLS = %w[Read Glob Grep].freeze

    # PROFONDITÀ della rilettura incrociata pretesa dalla fase (CYRA-285). La cross review resta obbligatoria
    # ovunque e il reviewer resta sempre il runtime opposto: cambia COSA le si chiede, non SE serve.
    #   - "result" (fasi READ) — la fase non tocca il repository e consegna un result strutturato: si rilegge
    #     quello (schema, coerenza col ticket, nessun effetto fuori dal tipo della fase). Non c'è un diff da
    #     guardare, e pretendere la stessa sessione dell'autopilot per farsi dire di sì sui cinque campi del
    #     triage costava una sessione intera per fase leggera.
    #   - "diff" (fasi WRITE) — la fase muta il repository: la rilettura resta quella piena sul diff.
    REVIEW_DEPTH_RESULT = "result"
    REVIEW_DEPTH_DIFF = "diff"

    PROFILES = {
      # Le fasi READ ESEGUONO i propri script (leggono il ticket con `cyi`, postano l'unico commento di
      # chiarimento, compongono il risultato con gli helper node della skill): senza esecuzione non fanno
      # NIENTE. `plan` — usato qui fino al 2026-07-30 — non impedisce le scritture, impedisce l'esecuzione:
      # in headless ogni chiamata Bash finiva in `permission_denials` e la sessione si arrendeva scrivendo
      # in prosa perché non aveva strumenti. È la causa per cui nessuna lavorazione è mai stata conclusa.
      #
      # La sola-lettura di queste fasi NON è mai stata il permission_mode, ed è ciò che le tiene tali:
      #   - `sandbox: nil` → nessun worktree gestito viene preparato, e l'hook `require-worktree` consente
      #     Edit/Write/MultiEdit/NotebookEdit SOLO dentro un worktree gestito → ogni scrittura è negata;
      #   - i sottoprocessi Bash girano nella sandbox OS fail-closed dei guardrail (`failIfUnavailable`,
      #     `allowUnsandboxedCommands: false`) con allowlist di rete;
      #   - `block-production`, `block-destructive-db`, `guard-branch-push` e la command policy restano
      #     autoritativi, come per le fasi WRITE.
      # `write_access?` resta false: dipende dalla sandbox, non dal permission_mode.
      "triage" => {
        skill_key: "/closeyourit-triage", runtime: "claude", sandbox: nil,
        permission_mode: "bypassPermissions", allowed_tools: READ_ONLY_TOOLS, ttl: DEFAULT_TTL_SECONDS
      },
      "planner" => {
        skill_key: "/closeyourit-planner", runtime: "claude", sandbox: nil,
        permission_mode: "bypassPermissions", allowed_tools: READ_ONLY_TOOLS, ttl: DEFAULT_TTL_SECONDS
      },
      "autopilot" => {
        skill_key: "/closeyourit-autopilot", runtime: "claude", sandbox: "workspace-write",
        permission_mode: "bypassPermissions", allowed_tools: [].freeze, ttl: DEFAULT_TTL_SECONDS
      },
      "closer_staging" => {
        skill_key: "/closeyourit-closer-staging", runtime: "claude", sandbox: "workspace-write",
        permission_mode: "bypassPermissions", allowed_tools: [].freeze, ttl: DEFAULT_TTL_SECONDS
      },
      "closer_production" => {
        skill_key: "/closeyourit-closer-production", runtime: "claude", sandbox: "workspace-write",
        permission_mode: "bypassPermissions", allowed_tools: [].freeze, ttl: DEFAULT_TTL_SECONDS
      }
    }.tap { |profiles| profiles.each_value { |attrs| attrs.each_value(&:freeze).freeze } }.freeze

    PHASES = PROFILES.keys.freeze

    class << self
      def phases = PHASES
      def known?(phase) = PROFILES.key?(phase.to_s)

      # Lookup indulgente: profilo o nil per una fase sconosciuta (fail-closed, nessuna eccezione).
      def for(phase) = known?(phase) ? new(phase.to_s) : nil

      # Lookup stretto: solleva KeyError su una fase sconosciuta (per i percorsi che DEVONO avere un
      # profilo, es. il claim host-scoped).
      def fetch(phase)
        raise KeyError, "unknown execution_phase: #{phase.inspect}" unless known?(phase)

        new(phase.to_s)
      end
    end

    attr_reader :phase

    # La fase è copiata e congelata: l'identità dell'oggetto (phase/attributi/hash) non dipende da una
    # stringa esterna mutabile passata dal chiamante.
    def initialize(phase)
      @phase = phase.to_s.dup.freeze
    end

    def known? = PROFILES.key?(phase)
    def skill_key = attributes.fetch(:skill_key)
    def runtime = attributes.fetch(:runtime)
    def sandbox = attributes.fetch(:sandbox)
    def permission_mode = attributes.fetch(:permission_mode)
    def allowed_tools = attributes.fetch(:allowed_tools)
    def ttl = attributes.fetch(:ttl)

    # Write-access = la fase muta il repository (sandbox workspace-write), derivato dalla sola fase.
    def write_access? = sandbox == "workspace-write"

    # Profondità della rilettura incrociata dovuta per questa fase.
    #
    # CYAU-176 — NON deriva più da `write_access?`. La derivazione diceva "questa fase può scrivere nel
    # repository, quindi c'è un diff da rileggere", e sulle due fasi che rilasciano è falso: quelle non
    # scrivono codice e non eseguono prove — spostano e marchiano. Peggio, quando un rilascio è andato a
    # buon fine le modifiche non sono più in attesa, sono già dentro il ramo principale: da confrontare non
    # resta niente, il controllo andava a vuoto e la lavorazione risultava fallita anche a rilascio
    # perfettamente riuscito — cioè il rilascio in produzione non partiva.
    #
    # Perciò è una tabella esplicita e non una deduzione: la domanda "c'è un diff da rileggere?" non ha la
    # stessa risposta di "questa fase ha il permesso di scrivere?", e dedurre l'una dall'altra è proprio
    # ciò che ha prodotto il guasto. Una fase nuova deve dichiararsi qui: fase sconosciuta → nil, e
    # Attempts::Deliver è fail-closed su nil.
    #
    # NON è una chiave di PROFILES di proposito. Quell'hash è il profilo di ESECUZIONE: viene denormalizzato
    # sulle colonne immutabili dell'attempt (`assign_attributes(**profile.to_h)` in TicketQueues::Claim) e
    # concorre a #digest, l'impronta pinnata sul lease e riconfrontata fail-closed alla consegna. Aggiungerla
    # lì pretenderebbe una colonna nuova e sposterebbe il digest di tutte e cinque le fasi, invalidando ogni
    # lavorazione in volo senza che nulla di come la sessione gira sia cambiato. Qui è una regola di
    # VALIDAZIONE della consegna, e come tale resta autoritativa server-side (Attempts::Deliver).
    REVIEW_DEPTHS = {
      "triage" => REVIEW_DEPTH_RESULT,
      "planner" => REVIEW_DEPTH_RESULT,
      "autopilot" => REVIEW_DEPTH_DIFF,
      "closer_staging" => REVIEW_DEPTH_RESULT,
      "closer_production" => REVIEW_DEPTH_RESULT
    }.freeze

    def review_depth = REVIEW_DEPTHS[phase]

    # CYRA-741 — CHI applica l'effetto quando una consegna di questa fase passa. La consegna
    # (Agents::Attempts::Deliver) non conosce più le cinque fasi una per una: chiede alla fase quale
    # sia il suo pezzo e lo esegue. Aggiungere una fase è dichiararla qui e scrivere il suo pezzo,
    # non riaprire il file più delicato del sistema.
    #
    # Nomi in stringa e non costanti: il profilo è un modello e gli effetti sono service, e nominarli
    # qui a caricamento li tirerebbe dentro al boot del modello. La risoluzione è pigra, come per i
    # parser di Vulnerabilities::Parse.
    #
    # NON è una chiave di PROFILES, per la stessa ragione di REVIEW_DEPTHS: quell'hash è il profilo di
    # ESECUZIONE, viene denormalizzato sulle colonne immutabili dell'attempt e concorre a #digest —
    # aggiungerlo lì sposterebbe il digest di tutte e cinque le fasi e invaliderebbe ogni lavorazione
    # in volo, senza che nulla di come la sessione gira sia cambiato.
    EFFECTS = {
      "triage" => "Agents::Attempts::Effects::Triage",
      "planner" => "Agents::Attempts::Effects::Planner",
      "autopilot" => "Agents::Attempts::Effects::Autopilot",
      "closer_staging" => "Agents::Attempts::Effects::CloserStaging",
      "closer_production" => "Agents::Attempts::Effects::CloserProduction"
    }.freeze

    # La classe dell'effetto, o nil per una fase che nessuno ha dichiarato: fail-closed come il resto
    # del profilo, e la consegna respinge invece di inventarne uno.
    def effect = EFFECTS[phase]&.constantize

    def to_h = attributes.dup

    # Impronta canonica (ordine-indipendente) del profilo di esecuzione della fase. Pinnata sul lease
    # host-first alla presa (profile_digest) e riconfrontata fail-closed alla consegna/renew: un drift
    # del profilo invalida il lavoro in volo. La Selection firmerà lo stesso digest (CYAU-79/80).
    def digest = Digest::SHA256.hexdigest(JSON.generate(to_h.sort_by { |key, _| key.to_s }.to_h))

    def ==(other) = other.is_a?(PhaseProfile) && other.phase == phase
    alias_method :eql?, :==
    def hash = phase.hash

    private

    def attributes = PROFILES.fetch(phase)
  end
end
