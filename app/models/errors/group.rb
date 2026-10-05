# frozen_string_literal: true

module Errors
  # Issue deduplicata: tutte le occorrenze con lo stesso fingerprint, in un progetto, sono UN gruppo.
  # I contatori (events/users) e first/last_seen vengono aggiornati atomicamente da Errors::Ingest::Record.
  # Il namespace Errors NON ha table_name_prefix (app/errors/ è il root di AppError top-level): tabella esplicita.
  class Group < ApplicationRecord
    self.table_name = "errors_groups"

    # Colonna infrastrutturale vector(1024), popolata SOLO da Errors::EmbedGroupJob:
    # abilita i candidati "errori simili" via similarità semantica (vedi FindSimilarGroups).
    has_neighbors :embedding

    # CYRA-168: solo le righe embeddate con la versione CORRENTE del modello. Da anteporre a ogni
    # nearest_neighbors così un re-embed in corso (righe di versioni miste) non falsa le distanze.
    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    belongs_to :project, class_name: "Projects::Project", inverse_of: :error_groups
    # Ticket collegato all'errore. `inverse_of` esplicito (CYRA-163): la vista del ticket risale al
    # gruppo di origine e senza di esso Rails ricaricherebbe l'oggetto invece di riusare quello in
    # memoria.
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :error_group, optional: true
    # Assegnatario (CYRA-153): chi si fa carico dell'errore, come l'assignee dei ticket. Facoltativo
    # (un errore può restare di nessuno). La FK ha on_delete: :nullify a livello DB.
    belongs_to :assignee, class_name: "Accounts::Account", inverse_of: :assigned_error_groups, optional: true
    has_many :events, class_name: "Errors::Event", foreign_key: :group_id,
             inverse_of: :group, dependent: :destroy
    # Log collegati manualmente a questo errore (vedi Logs::Link).
    has_many :log_links, class_name: "Logs::Link", as: :linkable, dependent: :destroy
    has_many :linked_log_entries, through: :log_links, source: :log_entry

    # Vocabolario fisso degli SDK Sentry (integrazione esterna) → enum legittimo (rules/lookup-tables.md).
    enum :level, { debug: 0, info: 1, warning: 2, error: 3, fatal: 4 }, prefix: true
    # Stati di triage gestiti dal sistema/operatore (workflow tecnico) → enum legittimo.
    enum :status, { unresolved: 0, resolved: 1, ignored: 2 }, prefix: true

    validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
    validates :title, presence: true
    # Isolamento tenant (anti-BOLA, come Ticketing::Ticket): l'assignee dev'essere membro dell'org del
    # progetto. Gli Account sono N:M con le org via Connections::Membership (niente organization_id diretto).
    validate :assignee_belongs_to_organization

    scope :recent, -> { order(last_seen_at: :desc) }

    # Istogramma "occorrenze nel tempo": stesso schema di Metrics/uptime (date_bin Postgres, 1 query).
    # No 1y: gli eventi sono potati a >30g (Errors::PruneEventsJob).
    RANGES = { "30m" => 30.minutes, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    DEFAULT_RANGE = "24h"

    BUCKETS = {
      "30m" => { count: 30, interval: "1 minute",   seconds: 60 },
      "24h" => { count: 48, interval: "30 minutes", seconds: 1_800 },
      "7d"  => { count: 56, interval: "3 hours",     seconds: 10_800 },
      "30d" => { count: 30, interval: "1 day",       seconds: 86_400 }
    }.freeze

    def self.range_duration(key) = RANGES.fetch(key, RANGES[DEFAULT_RANGE])
    def self.bucket_config(range) = BUCKETS.fetch(range, BUCKETS[DEFAULT_RANGE])

    # Conteggio occorrenze per blocco temporale, per N gruppi in 1 query (date_bin), niente N+1.
    # Ritorna { group_id => [ {count:, at:}, ... count ] } ordinato vecchio→nuovo; blocchi senza eventi → count 0.
    # `at:` = istante d'inizio del blocco (per label asse X e finestra oraria del tooltip in vista).
    # Istogramma di FREQUENZA: l'altezza della barra ∝ count (nessun avg/status).
    #
    # CYRA-562 — `events:` restringe il conteggio a un insieme di occorrenze scelto dal chiamante
    # (ambiente, rilascio, livello del dettaglio errore). Serve perché il grafico e la tabella sotto
    # devono descrivere LO STESSO insieme: finché qui passavano sempre tutte le occorrenze, filtrare
    # a un ambiente senza eventi lasciava le colonne piene sopra la frase «nessun evento conservato».
    # Chi non ha filtri (dashboard progetto, rilevamento picchi) non cambia una riga.
    def self.buckets_for(group_ids, range, now = Time.current, events: Errors::Event.all)
      cfg = bucket_config(range)
      ids = Array(group_ids).uniq
      return {} if ids.blank?

      since = now - (cfg[:count] * cfg[:seconds])
      conn = connection
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, occurred_at, #{conn.quote(since)}::timestamptz)"
      # `reorder(nil)`: l'insieme arriva dalla tabella delle occorrenze, che è ordinata per istante —
      # e un ORDER BY su colonna non aggregata fa fallire la GROUP BY in Postgres. Toglierlo qui,
      # e non ricordarselo a ogni chiamata, è l'unico modo perché non torni a rompersi.
      rows = events.reorder(nil).where(group_id: ids, occurred_at: since...now)
                   .group(Arel.sql("group_id"), Arel.sql(bin))
                   .pluck(Arel.sql("group_id"), Arel.sql(bin), Arel.sql("COUNT(*)"))

      result = ids.index_with { Array.new(cfg[:count]) { |i| { count: 0, at: since + (i * cfg[:seconds]) } } }
      rows.each do |gid, bucket_time, count|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        # Guard difensiva: la query filtra occurred_at in [since, now) e date_bin ha origine `since`
        # con lo stesso interval → idx è sempre in [0, count-1]. Il ramo `next` è irraggiungibile.
        # simplecov:disable
        next unless idx.between?(0, cfg[:count] - 1)
        # simplecov:enable

        result[gid][idx] = { count: count, at: since + (idx * cfg[:seconds]) }
      end
      result
    end

    def promoted? = ticket_id.present?

    # CYRA-380: il gruppo ha MAI ricevuto il contesto utente? Fatto storico monotòno (user_context_seen:
    # una volta true resta true), distinto da users_count — che è un lower-bound «almeno tanti» che
    # Errors::Split#recount! ricalcola dagli eventi conservati e Errors::Merge fa col max: dopo split +
    # potatura può tornare a zero pur avendo tracciato. Il flag no: Ingest::Record lo accende al primo
    # user_hash e nessuno lo spegne. La vista mostra «non tracciato» + link alla guida invece di 0/—.
    def user_context_tracked? = user_context_seen?

    private

    def assignee_belongs_to_organization
      return if assignee.nil?

      org_id = project&.organization_id
      return if org_id.blank?

      errors.add(:assignee, :not_member) unless Connections::Membership.exists?(
        account_id: assignee_id, organization_id: org_id
      )
    end
  end
end
