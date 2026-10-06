# frozen_string_literal: true

module Member
  # Agents (sezione AI) — host-first (CYAU-88): /member/agents elenca gli HOST (i Mac) e la loro
  # attività. Un host = 1 identità che reclama la prossima fase pronta di un ticket ed esegue la skill
  # di quella fase (heartbeat/attività = CYAU-31). I 5 typed agent restano nel DB (rimozione = CYAU-85),
  # ma non hanno più UI. Lettura gated agents.view (org-level, manage-implies-view); certificazione
  # (via libera umano) gated agents.manage. Classe FLAT nel modulo Member (MAI Member::Agents::AgentsController:
  # ombreggerebbe ::Agents di dominio) → model SEMPRE ::Agents::Host.
  class AgentsController < Member::BaseController
    before_action :require_view
    before_action :set_host, only: %i[show certify decertify destroy review engine follow_organization]
    before_action :require_manage, only: %i[certify decertify destroy review engine follow_organization]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :kind, :enabled, :q, :sort, only: :index

    def index
      # La fleet host è piccola (una manciata di Mac): carico org-wide e valuto online/offline per riga
      # in Ruby (nessuno scope SQL online/offline — la soglia dipende dalle colonne interval+grace del
      # singolo host). Zero N+1: stato, slot, attività (active_runs jsonb) e heartbeat vivono sull'host.
      all = current_organization.agent_hosts.order(last_heartbeat_at: :desc, hostname: :asc).to_a
      @online_count = all.count(&:heartbeat_online?)
      @offline_count = all.size - @online_count
      # CYRA-450: i "fermi" sono un sottoinsieme degli offline (silenzio oltre la soglia di allarme) — il
      # conteggio distingue una macchina appena offline da una dimenticata accesa e ormai morta.
      @stale_count = all.count(&:heartbeat_stale?)
      @total_count = all.size
      # CYRA-924 — paged like every table (T7); the counts above still cover the whole fleet.
      @pagination = Pagination.from_array(sorted_rows(filter_by_query(all), columns: host_sort_columns),
                                          page: params[:page], per: requested_per(Pagination::DEFAULT_PER))
      @hosts = @pagination.records
    end

    # CYRA-823 — la scheda dice due cose diverse: che cosa la macchina sta facendo ADESSO (cambia da
    # sola, la si guarda) e che cosa ha già chiuso (si sfoglia). Tenerle in un blocco unico costava
    # ogni volta il conto dell'altra metà: seguire una lavorazione ricalcolava rendimento e storico,
    # girare pagina nello storico ricalcolava attività e confronto fra periodi.
    #
    # Il confine è un frame per parte, e la richiesta di frame la si riconosce dall'intestazione che
    # manda Turbo — NON da un parametro nell'indirizzo: così il collegamento che si condivide resta
    # quello della pagina intera, con dentro periodo, filtri e pagina, e chi lo apre vede tutto.
    # Un endpoint solo, quindi anche un gate solo: `require_view` e `set_host` valgono per costruzione
    # anche sui frame (compreso il 404 anti-BOLA sull'host di un'altra organizzazione).
    # Il nome del frame dell'attività è lo stesso che il segnale realtime bersaglia: sta in un posto
    # solo (::Agents::Hosts::Broadcast), altrimenti un rinominio da un lato spegne gli aggiornamenti
    # senza rompere niente di visibile.
    ACTIVITY_FRAME = ::Agents::Hosts::Broadcast::ACTIVITY_FRAME
    WORKED_FRAME = "host-worked"

    # CYRA-924 — the runtimes the host declares, sorted in memory (C9).
    RUNTIME_SORT_COLUMNS = {
      "name" => ->(runtime) { runtime["name"].to_s.downcase.presence },
      "version" => ->(runtime) { Gem::Version.correct?(runtime["version"].to_s) ? Gem::Version.new(runtime["version"]) : nil }
    }.freeze

    def show
      return render_activity if turbo_frame_request_id == ACTIVITY_FRAME
      return render_worked if turbo_frame_request_id == WORKED_FRAME

      load_activity
      load_performance
      load_worked
      # Le sigle dei progetti che l'host dichiara di seguire diventano nomi per esteso, ma solo per i
      # progetti che chi legge può davvero aprire (anti-BOLA): le altre restano sigle.
      @repository_projects = visible.projects.where(key: @host.repositories).index_by(&:key)
      @runtimes = sorted_rows(@host.runtimes, columns: RUNTIME_SORT_COLUMNS, param: :runtimes_sort)
      # Anti-BOLA: `agents.view` è ORG-level, la visibilità dei ticket è per-progetto. Senza questo filtro
      # chi vede gli host ma non il progetto leggerebbe titolo, ramo e PR di un ticket che non gli compete.
      # L'attività dell'host resta visibile (codice + percorso): è il contenuto del ticket a essere gated.
      # Un solo pluck per entrambe le sezioni — l'attività in corso e lo storico condividono il gate.
      @visible_ticket_ids = visible_ids_for(activity_tickets + worked_tickets)
    end

    # CYRA-451 — due host affiancati sullo stesso periodo: «di chi mi fido di più» è una domanda di
    # confronto, e leggerla saltando fra due schede costringeva a ricordare i numeri a memoria.
    # Sola lettura, stesso gate della lista (agents.view).
    def compare
      @range = ::Agents::Hosts::StatsRange.normalize(params[:range])
      @hosts = current_organization.agent_hosts.order(hostname: :asc).to_a
      selected = Array(params[:host_ids]).map(&:to_s).uniq
      @selected = @hosts.select { |host| selected.include?(host.id) }
      @selected = @hosts.first(2) if @selected.empty?
      @reports = ::Agents::Hosts::Comparison.call(hosts: @selected, range: @range)
    end

    # B.1b — via libera umano: certifica l'host (certified_at + certified_by), abilitandolo al gate di
    # eleggibilità (Agents::Hosts::Eligibility). Solo agents.manage.
    def certify
      result = ::Agents::Hosts::Certify.call(host: @host, actor: Current.account)
      flash_message = result.ok? ? { notice: t("member.agents.certify_ok") } : { alert: result.error.message }
      redirect_to(member_agent_path(@host), **flash_message)
    end

    # CYAU-226 — which engine reviews this machine's work before delivery, by name.
    def review
      if @host.update(reviewer: params[:reviewer])
        redirect_to member_agent_path(@host), notice: t("member.agents.review.updated")
      else
        reason = @host.errors.of_kind?(:reviewer, :opencode_model_missing) ? "opencode_model_missing" : "invalid"
        redirect_to member_agent_path(@host), alert: t("member.agents.review.#{reason}")
      end
    end

    # CYRA-921 — which engine does this machine's work: Claude or Codex.
    def engine
      if @host.update(work_engine: params[:work_engine])
        redirect_to member_agent_path(@host), notice: t("member.agents.engine.updated")
      else
        redirect_to member_agent_path(@host), alert: t("member.agents.engine.invalid")
      end
    end

    # CYAU-227 — the machine drops its own choice and follows the organization's from the next job.
    def follow_organization
      @host.update!(work_engine: nil, reviewer: nil)
      redirect_to member_agent_path(@host), notice: t("member.agents.choice.followed")
    end

    def decertify
      ::Agents::Hosts::Decertify.call(host: @host)
      redirect_to member_agent_path(@host), notice: t("member.agents.decertify_ok")
    end

    # CYRA-516 — la macchina dismessa esce dall'elenco, e con lei il suo storico (le FK non lasciano
    # scelta: `agents_attempts.host_id` è NOT NULL con `on_delete: :restrict`). Il rifiuto quando c'è
    # lavoro in corso torna sulla scheda, dove l'attività in corso è sotto gli occhi di chi ha premuto.
    def destroy
      result = ::Agents::Hosts::Destroy.call(host: @host)
      return redirect_to(member_agent_path(@host), alert: t("member.agents.destroy_busy")) if result.err?

      redirect_to member_agents_path, notice: t("member.agents.destroy_ok", **result.value)
    end

    private

    # Il frame dell'ATTIVITÀ: l'elenco delle lavorazioni in corso e i contatori che lo descrivono,
    # nella STESSA risposta. Stanno insieme perché sono la stessa osservazione: separarli in due
    # richieste rimetterebbe in pagina proprio la contraddizione di CYRA-498 — l'intestazione che
    # dice «0 in esecuzione» mentre sotto l'elenco ne mostra tre.
    def render_activity
      load_activity
      @visible_ticket_ids = visible_ids_for(activity_tickets)
      render :activity, layout: false
    end

    # Il frame dello STORICO: solo la lista, con la sua pagina e i suoi filtri. Rendimento e
    # confronto fra periodi non si ricalcolano — non cambiano sfogliando, e sono la parte cara.
    def render_worked
      load_worked
      @visible_ticket_ids = visible_ids_for(worked_tickets)
      render :worked, layout: false
    end

    def load_activity
      # CYRA-448 — quante decisioni questa macchina sta aspettando da chi guarda: la stessa coda
      # della pagina Approvazioni, filtrata su di lei. Riusa la Queue invece di ricontare: due
      # conteggi che divergono sono peggio di nessun conteggio.
      @waiting_decisions = ::Home::Approvals::Queue.call(
        account: Current.account, organization: current_organization,
        visible_projects: visible.projects, visible_tickets: visible.tickets,
        agent: @host.id
      ).total
      @can_manage = can?("agents.manage")
      # CYRA-516 — l'eliminazione è definitiva: la conferma deve dire quanto storico porta via, non
      # limitarsi a "sei sicuro?". Tre count, solo per chi ha davvero il pulsante.
      @history_size = ::Agents::Hosts::Destroy.history_size(@host) if @can_manage
      @active_runs = @host.observable_active_runs
      # CYRA-183: il percorso per fase si legge dal workflow del ticket sotto lease. Precarico workflow,
      # piani, tentativi e branch/PR in un colpo: la sezione può elencare più lavorazioni e ognuna
      # interrogherebbe altrimenti il DB per riga.
      @active_leases = @host.leases.where("expires_at > ?", Time.current)
                            .includes(ticket: [ { agent_workflow: %i[plans attempts] }, :github_branches, :github_pull_requests ])
                            .order(:expires_at).to_a
      # L'ELENCO viene dallo snapshot, non dai lease vivi: una run **ferma** ha per definizione il lease
      # scaduto e sparirebbe dalla query proprio quando l'operatore deve vederla (ed è anche l'unico caso
      # in cui esiste il badge `expired`). Il lease, quando c'è, arricchisce la riga con la fase in corso.
      @runs_by_ticket_code = @active_runs.index_by { |run| run["ticket"] }
      @leases_by_ticket_code = @active_leases.index_by { |lease| lease.ticket&.code }
      @tickets_by_code = resolve_tickets_by_code(@runs_by_ticket_code.keys.compact)
      @active_attempts = ::Agents::Attempt.where(host_id: @host.id, status: %i[running awaiting_review])
                                          .includes(workflow: :ticket).order(started_at: :desc).to_a
      # CYRA-498 — i tre contatori della scheda leggevano sorgenti diverse e si contraddicevano:
      # l'intestazione diceva «0 in esecuzione», il riquadro «nessuna attività» e sotto, in piccolo,
      # «Attempt attivi: 5». La verità mostrata è UNA — le lavorazioni che la macchina dichiara — e
      # i lavori che risultano aperti solo a database diventano un avviso esplicito, non un numero
      # che smentisce gli altri: è il caso di una macchina che si è fermata senza chiuderli.
      declared = @active_runs.filter_map { |run| run["ticket"] }.to_set
      @unreported_attempts = @active_attempts.reject { |attempt| declared.include?(attempt.workflow&.ticket&.code) }
    end

    # CYRA-279 — storico e rendimento condividono il PERIODO: i numeri in cima devono descrivere le
    # righe che stanno sotto, non un'altra finestra. Il periodo sta in un metodo suo proprio perché
    # lo storico si ricarica anche da solo, e resta lo stesso.
    def range = @range ||= ::Agents::Hosts::StatsRange.normalize(params[:range])

    # Gli aggregati del periodo: la parte cara, e quella che sfogliando lo storico non cambia.
    def load_performance
      @performance = ::Agents::Hosts::Performance.call(host: @host, range: range)
      # CYRA-451 — il periodo precedente della stessa ampiezza: senza una base, «21,6% respinti» non
      # dice se sta migliorando. Su `all` non c'è un prima, e il confronto non si chiede nemmeno.
      @previous = ::Agents::Hosts::Performance.call(host: @host, range: range, previous: true) if range != "all"
    end

    def load_worked
      @work_filters = ::Agents::Hosts::WorkedTickets.filters_from(phase: params[:phase], outcome: params[:outcome])
      # `per` viaggia già nei link del footer di paginazione: leggerlo qui è ciò che li rende veri
      # (il servizio lo clampa da sé). Senza, scegliere quante righe per pagina non aveva effetto.
      @worked = ::Agents::Hosts::WorkedTickets.call(host: @host, range: range, page: params[:page],
                                                    per: params[:per].presence || ::Pagination::DEFAULT_PER,
                                                    phase: @work_filters[:phase], outcome: @work_filters[:outcome],
                                                    sort: params[:worked_sort])
    end

    # I ticket nominati dalle due sezioni: il gate di visibilità è lo stesso, cambia solo l'insieme
    # a cui applicarlo (la pagina intera li unisce in un pluck solo).
    def activity_tickets = @tickets_by_code.values

    def worked_tickets = @worked.records.filter_map(&:ticket)

    # Anti-BOLA + scoping org-level: host di un'altra org → RecordNotFound.
    def set_host
      @host = current_organization.agent_hosts.find(params[:id])
    end

    # Lo snapshot cita i ticket per CODICE, che non è una colonna ma `project.key + "-" + number`:
    # la traduzione vive in ::Ticketing::CodeReference (una query per N codici, niente N+1). Gli
    # `includes` restano qui perché sono di QUESTA pagina, non del servizio.
    def resolve_tickets_by_code(codes)
      references = codes.filter_map { |code| ::Ticketing::CodeReference.parse(code) }
      ::Ticketing::CodeReference
        .resolve(scope: ::Ticketing::Ticket.all, projects: current_organization.projects, references: references)
        .includes(:project, { agent_workflow: %i[plans attempts] }, :github_branches, :github_pull_requests)
        .index_by(&:code)
    end

    # Sottoinsieme VISIBILE (per-progetto) di un insieme di ticket già in memoria, in una query.
    # Riceve sia i ticket dell'attività in corso sia quelli dello storico: il gate è lo stesso e
    # tenerlo in un punto solo evita che una delle due sezioni se lo dimentichi.
    def visible_ids_for(tickets)
      ids = tickets.compact.map(&:id).uniq
      return Set.new if ids.empty?

      visible.tickets.where(id: ids).pluck(:id).to_set
    end

    # Ricerca su hostname/fingerprint. Filtro in Ruby (fleet piccola) per non duplicare la logica
    # heartbeat_online? in SQL.
    def filter_by_query(hosts)
      return hosts if search_q.blank?

      needle = search_q.downcase
      hosts.select { |host| host.hostname.to_s.downcase.include?(needle) || host.fingerprint.to_s.downcase.include?(needle) }
    end

    def require_view
      return if can_view_agents?

      require_permission!("agents.view")
    end

    def require_manage
      require_permission!("agents.manage")
    end

    def search_q = params[:q].to_s.strip

    # CYRA-924 — every column sorts (C9); the fleet is a handful of machines, sorted in memory.
    def host_sort_columns
      {
        "host" => ->(host) { host.hostname.to_s.downcase },
        "status" => ->(host) { helpers.agent_host_status_label(host) },
        "activity" => ->(host) { helpers.agent_host_activity_summary(host) },
        "slots" => ->(host) { host.running.to_i },
        "heartbeat" => ->(host) { host.last_heartbeat_at }
      }
    end
  end
end
