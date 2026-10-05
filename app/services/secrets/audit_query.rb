# frozen_string_literal: true

module Secrets
  # Query object dell'audit del Vault (CYRA-135): unifica in LETTURA gli eventi dei secret org-scoped
  # (variabili di progetto, variabili shared, file) in righe normalizzate ordinate dal piu recente.
  # Scoping di sicurezza: gli eventi legati a un progetto sono limitati ai progetti visibili
  # (visible_project_ids). Gli eventi PERSONALI (account-scoped) NON entrano nell'audit org.
  class AuditQuery
    # Riga d'audit normalizzata: forma unica su cui la view non deve conoscere i 3 schemi sorgente.
    # `channel` (web / cli) exists on project variable events only: nil elsewhere.
    Row = Data.define(:occurred_at, :source, :action, :actor, :project_id, :environment_id, :name, :metadata, :channel)

    # I 3 registri org-scoped che questa vista unifica. Dichiarati una volta sola: le azioni per il
    # filtro si ricavano da qui, e il guard del registro unico (CYRA-745) legge questo elenco invece
    # di tenerne una copia a mano che può divergere.
    SOURCE_MODELS = [ Secrets::Event, Secrets::Shared::Event, Secrets::AssetEvent ].freeze

    # Tutte le azioni possibili nei 3 sorgenti org-scoped (per il filtro azione della UI).
    ACTIONS = SOURCE_MODELS.flat_map { |model| model::ACTIONS }.uniq.freeze

    # CYRA-745 — `limit:` opzionale (nil = tutte, comportamento invariato per chi non lo passa). Senza,
    # le tre tabelle si caricano INTERE in memoria e si ordinano in Ruby a ogni apertura della pagina:
    # finché il registro è giovane non si vede, con lo storico di un anno sì. Il taglio è sicuro perché
    # ogni lista arriva già ordinata dal database: le N più recenti dell'unione stanno nelle prime N di
    # ciascuna.
    # CYRA-924 — `oldest_first:` reverses the order end to end: each register is read oldest first,
    # so the cut keeps the oldest N rows of the union, not the newest.
    def initialize(organization:, visible_project_ids:, filters: {}, limit: nil, oldest_first: false)
      @organization = organization
      @visible_project_ids = Array(visible_project_ids)
      @filters = filters || {}
      @limit = limit&.to_i
      @oldest_first = oldest_first
    end

    def rows
      unite = (variable_rows + shared_rows + file_rows).sort_by(&:occurred_at)
      unite = unite.reverse unless @oldest_first
      @limit ? unite.first(@limit) : unite
    end

    # Quante righe ci sono davvero, contate dal database. Serve alla chip del titolo di chi impagina:
    # `rows.size` direbbe la dimensione della finestra, non quella del registro, e per saperlo
    # dovrebbe caricarlo tutto — che è esattamente ciò che `limit:` evita.
    def total
      SOURCE_MODELS.sum { |model| scope_for(model).count }
    end

    private

    # Le tre righe di scoping in un posto solo: le usano sia le liste sia il conteggio, e una divergenza
    # fra i due farebbe dire alla chip un numero che la tabella non può mostrare.
    def scope_for(model)
      case model.name
      when "Secrets::Event" then variable_events
      when "Secrets::Shared::Event" then shared_events
      else file_events
      end
    end

    def variable_rows
      limited(variable_events).map do |event|
        Row.new(occurred_at: event.created_at, source: :variable, action: event.action, actor: event.actor,
                project_id: event.project_id, environment_id: event.environment_id, name: event.name,
                metadata: event.metadata, channel: event.channel)
      end
    end

    def shared_rows
      limited(shared_events).map do |event|
        Row.new(occurred_at: event.created_at, source: :shared, action: event.action, actor: event.actor,
                project_id: event.project_id, environment_id: event.environment_id, name: event.name,
                metadata: event.metadata, channel: nil)
      end
    end

    def file_rows
      limited(file_events).map do |event|
        Row.new(occurred_at: event.created_at, source: :file, action: event.action, actor: event.actor,
                project_id: event.project_id, environment_id: event.environment_id, name: nil,
                metadata: event.metadata, channel: nil)
      end
    end

    def limited(relation) = @limit ? relation.limit(@limit) : relation

    # Eventi delle variabili di progetto (Secrets::Event) dei soli progetti visibili.
    def variable_events
      filtered(
        Secrets::Event
          .where(organization_id: @organization.id, project_id: @visible_project_ids)
          .includes(:actor, :environment, :project),
        named: true
      )
    end

    # Eventi delle variabili SHARED: org-level (la pagina e gia gated dal permesso org-level).
    def shared_events
      filtered(
        Secrets::Shared::Event
          .where(organization_id: @organization.id)
          .includes(:actor, :environment, :shared_variable),
        named: true
      )
    end

    # Eventi dei FILE segreti: dei progetti visibili PIU i file org-level (project_id nil = file shared).
    def file_events
      filtered(
        Secrets::AssetEvent
          .where(organization_id: @organization.id, project_id: @visible_project_ids + [ nil ])
          .includes(:actor, :environment, :asset),
        named: false
      )
    end

    # Filtri comuni ai 3 sorgenti. `named:` indica se la tabella ha la colonna `name` (variabili/shared
    # si, file no): la ricerca testuale `q` cerca nel nome del secret, quindi non si applica ai file
    # (che senza nome escono dai risultati quando c'e un termine di ricerca).
    def filtered(relation, named:)
      relation = relation.where(action: @filters[:action]) if @filters[:action].present?
      relation = relation.where(environment_id: @filters[:environment_id]) if @filters[:environment_id].present?
      relation = relation.where(actor_id: @filters[:actor_id]) if @filters[:actor_id].present?
      relation = relation.where(created_at: @filters[:from]..) if @filters[:from].present?
      relation = relation.where(created_at: ..@filters[:to]) if @filters[:to].present?
      if @filters[:q].present?
        return relation.none unless named

        relation = relation.where("name ILIKE ?", "%#{@filters[:q]}%")
      end
      @oldest_first ? relation.order(created_at: :asc) : relation.recent
    end
  end
end
