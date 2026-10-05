# frozen_string_literal: true

module Types
  # Crea gli status e le priorità di default di una organizzazione (colori dal design system).
  # Idempotente (find_or_create_by!): usato sia al signup sia dai seed.
  class InstallDefaults < ApplicationService
    # review_gate: l'ingresso in questo status avvisa il reviewer del ticket. Default su "In Review".
    STATUSES = [
      { code: "open",        label: "Open",        color: "amber",   position: 0, animated: false, category: :open,        review_gate: false },
      { code: "in_progress", label: "In Progress", color: "indigo",  position: 1, animated: true,  category: :in_progress, review_gate: false },
      { code: "in_review",   label: "In Review",   color: "violet",  position: 2, animated: true,  category: :in_progress, review_gate: true },
      { code: "resolved",    label: "Resolved",    color: "emerald", position: 3, animated: false, category: :done,        review_gate: false },
      { code: "closed",      label: "Closed",      color: "gray",    position: 4, animated: false, category: :done,        review_gate: false }
    ].freeze

    PRIORITIES = [
      { code: "low",    label: "Low",    color: "gray",   position: 0 },
      { code: "medium", label: "Medium", color: "amber",  position: 1 },
      { code: "high",   label: "High",   color: "orange", position: 2 }
    ].freeze

    # supports_uptime: solo le piattaforme web/server abilitano la sezione uptime (HTTP-ping).
    # supports_analytics: solo il web (pagine con browser) abilita la dashboard analytics (pageview).
    # supports_session_replay: solo il web (browser + rrweb) abilita il session replay.
    PLATFORMS = [
      { code: "ios",     label: "iOS",     color: "sky",     position: 0, supports_uptime: false, supports_analytics: false, supports_session_replay: false },
      { code: "android", label: "Android", color: "emerald", position: 1, supports_uptime: false, supports_analytics: false, supports_session_replay: false },
      { code: "web",     label: "Web",     color: "violet",  position: 2, supports_uptime: true, supports_analytics: true, supports_session_replay: true }
    ].freeze

    # servers_enabled / uptime_enabled / secrets_enabled: DEFAULT di capability per-ambiente (un progetto
    # può override-arli per sé sulla join). Matrice differenziata: uptime solo in produzione; il monitoring
    # server sparisce in development; i secret restano ovunque (ogni ambiente ha la sua config).
    # approval_required (CYRA-138, Fase 4 pezzo C1a): production parte protetto di default (l'ambiente più
    # sensibile), staging/development no — un progetto può comunque override-are per sé sulla join.
    ENVIRONMENTS = [
      { code: "production",  label: "Production",  color: "emerald", position: 0, servers_enabled: true,  uptime_enabled: true,  secrets_enabled: true, approval_required: true },
      { code: "staging",     label: "Staging",     color: "amber",   position: 1, servers_enabled: true,  uptime_enabled: false, secrets_enabled: true, approval_required: false },
      { code: "development", label: "Development",  color: "sky",     position: 2, servers_enabled: false, uptime_enabled: false, secrets_enabled: true, approval_required: false }
    ].freeze

    # Ciclo di vita di una funzionalità su una piattaforma (matrice di prodotto, CYRA-256).
    # `category` guida icona, marker "versione mancante" e validazioni: available/deprecated =
    # nelle mani degli utenti, quindi ci si aspetta una versione. unplanned e not_applicable
    # condividono il grigio: li distingue l'icona (mai fatto ≠ non ha senso qui), non il colore.
    FEATURE_STATUSES = [
      { code: "unplanned",      label: "Not planned",    color: "gray",    position: 0, category: :unplanned },
      { code: "planned",        label: "Planned",        color: "sky",     position: 1, category: :planned },
      { code: "in_development", label: "In development", color: "indigo",  position: 2, category: :in_development },
      { code: "available",      label: "Available",      color: "emerald", position: 3, category: :available },
      { code: "deprecated",     label: "Deprecated",     color: "amber",   position: 4, category: :deprecated },
      { code: "not_applicable", label: "Not applicable", color: "gray",    position: 5, category: :not_applicable }
    ].freeze

    def initialize(organization:, created_by: nil)
      @organization = organization
      @created_by = created_by
    end

    def call
      install(TicketStatus, STATUSES.map { |attrs| attrs.merge(category: TicketStatus.categories.fetch(attrs[:category].to_s)) })
      install(TicketPriority, PRIORITIES)
      install(Platform, PLATFORMS)
      install(Environment, ENVIRONMENTS)
      install(FeatureStatus, FEATURE_STATUSES.map { |attrs| attrs.merge(category: FeatureStatus.categories.fetch(attrs[:category].to_s)) })

      Result.ok(@organization)
    end

    private

    # Una sola INSERT ... ON CONFLICT DO NOTHING per lookup (insert_all con unique_by su
    # [organization_id, code]) invece di una find_or_create_by! per riga: conserva la semantica
    # "installa i mancanti, non toccare gli esistenti" senza generare N+1 nel setup delle spec.
    # I valori sono costanti già normalizzate → nessuna validazione/normalizzazione da eseguire.
    def install(model, entries)
      now = Time.current
      rows = entries.map do |attrs|
        attrs.merge(
          organization_id: @organization.id,
          created_by_id: @created_by&.id,
          created_at: now,
          updated_at: now
        )
      end
      model.insert_all(rows, unique_by: %i[organization_id code])
    end
  end
end
