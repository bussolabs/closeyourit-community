# frozen_string_literal: true

module Ticketing
  # Crea un ticket nell'org corrente. Risolve project/status/priority/assignee SCOPED all'org
  # (anti-BOLA); le validazioni tenant finali restano nel model. reporter = chi crea. Result pattern.
  class CreateTicket < ApplicationService
    def initialize(organization:, reporter:, params:, true_actor: nil)
      @organization = organization
      @reporter = reporter
      @params = params
      @true_actor = true_actor
    end

    def call
      @project = visible_projects.find_by(id: @params[:project_id])
      return err("R404-TICKET-001", :project_not_found) if @project.nil?

      ticket = @project.tickets.new(attributes.merge(reporter: @reporter))
      event = nil
      ApplicationRecord.transaction do
        ticket.save!
        ticket.create_agent_workflow!(triage_requested_at: Time.current)
        # reporter è l'attore di creazione (i ticket non hanno created_by).
        event = RecordActivity.call(ticket: ticket, actor: @reporter, true_actor: @true_actor,
                                    action: "created",
                                    # simplecov:disable status/priority obbligatorie (null:false) → dopo save! sempre
                                    # presenti; l'arm `&.label` con ricevente nil è difesa irraggiungibile.
                                    data: { status: ticket.status&.label, priority: ticket.priority&.label })
        # simplecov:enable
      end
      # Notifiche al team (fuori dalla transazione, evento committato). Vedi Ticketing::NotifyJob.
      Ticketing::NotifyJob.perform_later(event_id: event.id)
      # Embedding per ricerca semantica/duplicati (fuori dalla transazione, mai after_commit).
      Ticketing::EmbedTicketJob.perform_later(ticket_id: ticket.id)
      # Gate di eleggibilità agenti (CYRA-184): il ticket nasce `pending` — quindi già fuori dalla
      # coda — e questo job produce il primo verdetto. Il debounce copre il caso "creo e correggo
      # subito": la raffica di job che ne segue costa una sola chiamata LLM (guardia sul checksum).
      # Senza il servizio collegato non si accoda niente e il ticket resta pending (CYRA-548).
      Ticketing::AgentEligibilityQueue.enqueue(ticket: ticket)
      Result.ok(ticket)
    rescue ActiveRecord::RecordInvalid => e
      # Solo l'invalidità del TICKET è un 422 utente; un evento invalido (bug) deve propagare
      # e far rollback della creazione, non mascherarsi da errore di validazione del ticket.
      raise unless e.record == ticket

      Result.err(AppError.new(ticket.errors.full_messages.to_sentence,
                              code: "R422-TICKET-001", details: ticket.errors.to_hash))
    end

    private

    # Progetti su cui il reporter può aprire ticket → Authorization::VisibleScope (fonte unica:
    # link personali + dei team). SOLO owner (+god) vedono tutti; gli altri solo i collegati (strict).
    def visible_projects
      Authorization::VisibleScope.new(account: @reporter, organization: @organization).projects
    end

    def attributes
      base = {
        title: @params[:title],
        # default bug se il chiamante non passa kind (es. Errors::PromoteToTicket).
        kind: @params[:kind].presence || :bug,
        description: @params[:description],
        technical_analysis: @params[:technical_analysis],
        weight: @params[:weight].presence,
        due_at: @params[:due_at].presence,
        status: @organization.ticket_statuses.find_by(id: @params[:status_id]),
        priority: @organization.ticket_priorities.find_by(id: @params[:priority_id]),
        assignee: assignee,
        # Il revisore nasce = reporter (chi apre il ticket). Riassegnabile poi via SetReviewer.
        reviewer: @reporter,
        milestone: milestone,
        parent: parent,
        platforms: platforms
      }
      # Nested solo se presenti: scenarios_attributes=/conditions_attributes= con nil solleverebbe.
      base[:scenarios_attributes]  = @params[:scenarios_attributes]  if @params[:scenarios_attributes].present?
      base[:conditions_attributes] = @params[:conditions_attributes] if @params[:conditions_attributes].present?
      base
    end

    # Se il chiamante HA specificato un assignee_id, quello (scoped all'org, anti-BOLA): un id invalido
    # o non membro resta nil e NON ricade sul default (il default vale solo "in assenza di assignee
    # esplicito"; sostituirlo maschererebbe un tentativo anti-BOLA). Assignee_id assente → default
    # ereditato dalla gerarchia progetto → team → org.
    def assignee
      return explicit_assignee if @params[:assignee_id].present?

      default_assignee
    end

    def explicit_assignee
      @organization.accounts.find_by(id: @params[:assignee_id])
    end

    # Fallback progetto → team → org: primo default valorizzato che sia ANCORA membro dell'org
    # (@organization.accounts è scoped ai membri → un default rimosso dall'org viene saltato, come
    # l'assignee esplicito). Nessun default valido a nessun livello → nil (ticket non assegnato).
    def default_assignee
      default_assignee_candidate_ids.each do |account_id|
        account = @organization.accounts.find_by(id: account_id)
        return account if account
      end
      nil
    end

    def default_assignee_candidate_ids
      [
        @project.default_assignee_id,
        *team_default_assignee_ids,
        @organization.default_assignee_id
      ].compact.uniq
    end

    # Default degli eventuali team che gestiscono il progetto (via Connections::TeamProjectAccess),
    # ordinati per nome per un fallback deterministico quando più team hanno un default.
    def team_default_assignee_ids
      Teams::Team
        .joins(:project_accesses)
        .where(connections_team_project_accesses: { project_id: @project.id })
        .where.not(default_assignee_id: nil)
        .order(:name)
        .pluck(:default_assignee_id)
    end

    # Milestone risolta tra quelle del PROGETTO del ticket (anti-BOLA); opzionale.
    def milestone
      return nil if @params[:milestone_id].blank?

      @project.milestones.find_by(id: @params[:milestone_id])
    end

    # Epic padre risolto tra i ticket DELLO STESSO progetto (anti-BOLA); opzionale. Che sia davvero
    # un epic e che la gerarchia resti a un livello lo valida il model (errore → 422).
    def parent
      return nil if @params[:parent_id].blank?

      @project.tickets.find_by(id: @params[:parent_id])
    end

    # Piattaforme risolte SCOPED all'org (anti-BOLA: ids di altre org cadono). Il vincolo
    # "subset del progetto" è validato sul model (errore → 422).
    def platforms
      ids = Array(@params[:platform_ids]).reject(&:blank?)
      return [] if ids.empty?

      @organization.platforms.where(id: ids)
    end

    def err(code, key)
      Result.err(AppError.new(I18n.t("member.tickets.errors.#{key}"), code: code))
    end
  end
end
