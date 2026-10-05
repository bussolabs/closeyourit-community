# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Report "Richieste in attesa" (CYRA-138, Fase 4 pezzo C2b — UI): raccoglie org-wide, sui progetti
    # VISIBILI passati, le Secrets::ChangeRequest ancora pending — MA SOLO quelle su cui l'account
    # PUÒ AGIRE. ANTI-DISCLOSURE: una change request espone il NOME del secret nel campo `name` (il
    # `value` resta cifrato, ma il nome no) — un account che vede il progetto (visible.projects)
    # senza poterne gestire i secret non deve scoprire che nome di variabile è in revisione, A MENO
    # che sia stato lui stesso a proporla (la conosce già, l'ha scritta lui).
    #
    # Visibile sse: can?("secrets.manage", scope: project) OPPURE cr.requested_by_id == account.id.
    #
    # Query PRECARICATA in blocco (1 query + includes, indipendente dal numero di progetti/richieste) —
    # poi il filtro di visibilità gira in RUBY sui dati già caricati. Il permesso `can?` è VALUTATO UNA
    # VOLTA PER PROGETTO DISTINTO (Hash memoizzato project_id => bool): con N progetti e M richieste
    # pendenti (M può essere >> N, più richieste sullo stesso progetto), non si ripete la stessa
    # decisione RBAC per ogni richiesta — guard Prosopite bloccante sui request spec (nessuna query
    # per-progetto in loop: l'Authorization::Resolver condiviso qui sotto è già memoizzato per
    # istanza, come Alerting::Recipients.for_secrets).
    class Pending
      def initialize(account:, projects:)
        @account = account
        @projects = projects.to_a
        @project_ids = @projects.map(&:id)
      end

      # Le CR pending visibili all'account, dalla più vecchia (in attesa da più tempo, la più
      # urgente da smaltire) alla più recente — pattern "coda FIFO", diverso dal feed di audit
      # (che mostra il più recente in cima): qui è una to-do list da svuotare, non una cronologia.
      def requests
        @requests ||= candidates.select { |change_request| visible?(change_request) }.sort_by(&:created_at)
      end

      def count
        requests.size
      end

      # Quante l'account PUÒ decidere (approvare/rifiutare) — esclude sempre le proprie (4-eyes).
      def decidable_count
        requests.count { |change_request| can_decide?(change_request) }
      end

      # Quante sono state richieste dall'account stesso (può solo ritirarle, mai deciderle).
      def mine_count
        requests.count { |change_request| can_cancel?(change_request) }
      end

      def any?
        requests.any?
      end

      # Predicato per riga (view): approvare/rifiutare richiede il permesso di gestione sul progetto
      # E che l'account NON sia il richiedente (vincolo 4-eyes) — ridondante col guard del service
      # (Secrets::ChangeRequests::{Approve,Reject}, difesa in profondità), qui decide se MOSTRARE i
      # bottoni di decisione.
      def can_decide?(change_request)
        manage?(change_request.project_id) && environment_allowed?(change_request) &&
          change_request.requested_by_id != @account.id
      end

      # Solo il richiedente può ritirare la propria richiesta.
      def can_cancel?(change_request)
        change_request.requested_by_id == @account.id
      end

      private

      # 1 query + includes (project/environment/requested_by per la view), non una per progetto.
      def candidates
        @candidates ||= ::Secrets::ChangeRequest
          .where(project_id: @project_ids, status: :pending)
          .includes(:project, :environment, :requested_by)
          .to_a
      end

      # Managers need environment access; requesters can still withdraw their own pending request.
      def visible?(change_request)
        change_request.requested_by_id == @account.id ||
          (manage?(change_request.project_id) && environment_allowed?(change_request))
      end

      def environment_allowed?(change_request)
        @environment_access ||= ::Secrets::EnvironmentAccess.for_projects(account: @account, projects: @projects)
        @environment_access[change_request.project_id]&.allowed?(change_request.environment.code) || false
      end

      # can?("secrets.manage", scope: project) valutato UNA VOLTA per progetto distinto (memoizzato in
      # Ruby); il resolver sottostante è a sua volta condiviso e cache per-istanza (niente query
      # ripetute per progetti/richieste diversi, vedi Authorization::Resolver). Fail-closed: un
      # project_id fuori da @projects (chiamata impropria di can_decide?/can_cancel? con una CR non
      # passata da #requests) non gestisce nulla, MAI un KeyError verso il chiamante.
      def manage?(project_id)
        return manage_by_project[project_id] if manage_by_project.key?(project_id)

        project = projects_by_id[project_id]
        manage_by_project[project_id] = project ? resolver.can?("secrets.manage", scope: project) : false
      end

      def manage_by_project
        @manage_by_project ||= {}
      end

      def projects_by_id
        @projects_by_id ||= @projects.index_by(&:id)
      end

      def resolver
        @resolver ||= ::Authorization::Resolver.new(account: @account, organization: organization)
      end

      def organization
        @organization ||= @projects.first&.organization
      end
    end
  end
end
