# frozen_string_literal: true

module Ticketing
  # CYRA-739 — le opzioni dei select del modulo ticket, in un posto solo: progetti, stati, priorità,
  # persone, piattaforme, più le mappe che il form usa per filtrare milestone ed epic al cambio
  # progetto. Erano trentacinque righe di query dentro il controller della pagina, accanto a bacheca,
  # ricerca e doppioni; qui stanno accanto ai loro `.to_a` e ai loro preload, dove si vedono.
  #
  # La bacheca chiede il sottoinsieme leggero `board_filters`: filtrano per
  # progetto/priorità/assegnatario e non hanno un form da riempire, quindi piattaforme, milestone ed
  # epic sarebbero query buttate a ogni apertura.
  class FormOptions < ApplicationService
    Options = Data.define(:projects, :statuses, :priorities, :assignees, :platforms,
                          :project_platforms_map, :milestones, :milestones_project_map,
                          :milestone_projects, :epics, :epics_project_map,
                          :error_groups, :error_groups_project_map,
                          :metric_groups, :metric_groups_project_map)

    # How many open signals per kind and per project the bug form offers: the most recent ones, not
    # the whole history. Per project: one busy project must not push the others out of the list.
    SIGNALS_LIMIT = 50

    BoardFilters = Data.define(:projects, :priorities, :assignees)

    # `ticket` è quello in modifica (nil sul nuovo): serve a escluderlo dagli epic selezionabili.
    # `signals:` loads the open errors and slow operations, which only the new-ticket form offers.
    def initialize(organization:, projects:, ticket: nil, signals: false)
      @organization = organization
      @projects = projects
      @ticket = ticket
      @signals = signals
    end

    def call
      ordered_projects = @projects.order(:name)
      milestones = milestones_of(ordered_projects)
      epics = epics_of(ordered_projects)
      error_groups = open_signals(::Errors::Group, ordered_projects)
      metric_groups = open_signals(::Metrics::Group, ordered_projects)
      # CYRA-374 — chi può revisionare è chiunque nell'organizzazione, esattamente come chi può
      # essere assegnatario: STESSA relation, non una query gemella (la seconda `.map` della view
      # riusa i record già caricati).
      Options.new(
        projects: ordered_projects, statuses: @organization.ticket_statuses.active.ordered,
        priorities: @organization.ticket_priorities.active.ordered,
        assignees: @organization.accounts.order(:name),
        platforms: @organization.platforms.active.ordered,
        project_platforms_map: project_platforms_map(ordered_projects),
        milestones: milestones,
        milestones_project_map: milestones.to_h { |m| [ m.id.to_s, m.project_id.to_s ] },
        milestone_projects: milestones.to_h { |m| [ m.id.to_s, m.project&.name ] },
        epics: epics,
        epics_project_map: epics.to_h { |epic| [ epic.id.to_s, epic.project_id.to_s ] },
        error_groups: error_groups,
        error_groups_project_map: error_groups.to_h { |group| [ group.id.to_s, group.project_id.to_s ] },
        metric_groups: metric_groups,
        metric_groups_project_map: metric_groups.to_h { |group| [ group.id.to_s, group.project_id.to_s ] }
      )
    end

    class << self
      # Opzioni dei select filtro della bacheca (index).
      def board_filters(organization:, projects:)
        BoardFilters.new(projects: projects.order(:name),
                         priorities: organization.ticket_priorities.active.ordered,
                         assignees: organization.accounts.order(:name))
      end

      # Il primo stato della categoria "aperto", nell'ordine dell'organizzazione: è dove ogni ticket
      # comincia. Se l'org non ne ha nessuno (configurazione anomala) si lascia scegliere, invece di
      # far fallire la creazione con un campo vuoto e nascosto.
      def default_status_id(organization)
        organization.ticket_statuses.active.ordered.find(&:category_open?)&.id
      end

      # Non la più bassa: «Low» come proposta suggerisce che quello che stai scrivendo non conta.
      # Si sceglie `medium` per codice, non per posizione: un'org che riordina le priorità non deve
      # cambiare il significato del default.
      def default_priority_id(organization)
        priorities = organization.ticket_priorities.active.ordered
        (priorities.find { |priority| priority.code == "medium" } || priorities.second || priorities.first)&.id
      end

      # Pre-selezione piattaforme: se il progetto ne ha una sola → quella (a prescindere dal profilo);
      # altrimenti dal profilo (match per code), ristretta al progetto quando si apre da ?project_id=.
      def preselected_platform_ids(organization:, account:, project_id:)
        if project_id.present?
          project_platform_ids = organization.platforms.active
            .where(id: Connections::ProjectPlatform.where(project_id:).select(:platform_id))
            .pluck(:id)
          # Progetto con una sola piattaforma → prefill automatico, a prescindere dal profilo.
          return project_platform_ids if project_platform_ids.size == 1
        end

        codes = Array(account.platform_codes).reject(&:blank?)
        return [] if codes.empty?

        scope = organization.platforms.active.where(code: codes)
        scope = scope.where(id: project_platform_ids) if project_id.present?
        scope.pluck(:id)
      end
    end

    private

    # Milestone dei progetti visibili: il form le filtra per progetto selezionato (Stimulus).
    # .to_a forza UNA sola query, riusata sia dalle mappe sia dal .each della view (niente query
    # doppia): il select è un Ui::SelectComponent, che non porta attributi custom per-opzione
    # (niente data-project-id) — la mappa id milestone → id progetto viaggia come value JSON sul
    # form (vedi ticket_milestone_controller.js).
    # CYRA-398 — «S0 Fondamenta» compariva tre volte, una per progetto, indistinguibili fra loro:
    # il nome del progetto viaggia con la milestone e la vista lo mostra come riga di dettaglio.
    def milestones_of(projects)
      ::Projects::Milestone.where(project_id: projects.select(:id)).active.ordered.includes(:project).to_a
    end

    # Epic dei progetti visibili, per il select "Epic padre": stessa meccanica delle milestone
    # (mappa id → progetto come value JSON sul form, vedi ticket_parent_controller.js). Il ticket
    # in modifica è escluso: un ticket non può essere padre di sé stesso.
    def epics_of(projects)
      scope = ::Ticketing::Ticket.where(project_id: projects.select(:id))
                                 .kind_epic.includes(:project).order(:title)
      scope = scope.where.not(id: @ticket.id) if @ticket&.persisted?
      scope.to_a
    end

    # Errors and slow operations a new bug can be linked to: still open and without a ticket.
    # Same id → project map as the milestones.
    def open_signals(model, projects)
      return [] unless @signals

      ranked = model.where(project_id: projects.select(:id), ticket_id: nil).status_unresolved
                    .select("#{model.table_name}.*",
                            "ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY last_seen_at DESC) AS signal_rank")
      model.from(ranked, model.table_name).where("signal_rank <= ?", self.class::SIGNALS_LIMIT)
           .order(last_seen_at: :desc).to_a
    end

    # { project_id => [platform_id, …] } come stringhe (combaciano con option.value lato JS),
    # solo piattaforme attive (quelle mostrate nel select). Una sola query, niente N+1.
    def project_platforms_map(projects)
      active_ids = @organization.platforms.active.pluck(:id).to_set
      Connections::ProjectPlatform
        .where(project_id: projects.select(:id))
        .pluck(:project_id, :platform_id)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(project_id, platform_id), acc|
          acc[project_id.to_s] << platform_id.to_s if active_ids.include?(platform_id)
        end
    end
  end
end
