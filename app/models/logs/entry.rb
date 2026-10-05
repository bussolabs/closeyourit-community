# frozen_string_literal: true

module Logs
  # Voce di log immutabile (solo created_at). project_id denormalizzato per retention/scoping/
  # correlazione senza join. Idempotente su event_id per progetto (replay/at-least-once). I log sono
  # uno stream append-only: niente group/fingerprint/triage (a differenza di Errors::/Metrics::).
  # NB: colonne `data` (= attributes strutturati) e `logger_name` (= logger): i nomi `attributes`
  # e `logger` sono riservati da ActiveRecord.
  class Entry < ApplicationRecord
    # CYRA-750 — la tabella è divisa a fette mensili su `created_at`: da qui la chiave primaria
    # riportata a `id` e il gemello per la scrittura in blocco.
    include PartitionedTable

    %i[event_time_unix_nano observed_time_unix_nano].each do |name|
      attribute name, ActiveModel::Type::Decimal.new(precision: 20)
      self::Bulk.attribute name, ActiveModel::Type::Decimal.new(precision: 20)
    end


    belongs_to :project, class_name: "Projects::Project", inverse_of: :logs_entries

    # Collegamenti manuali a errori/ticket (la correlazione automatica è via trace_id, senza join).
    has_many :links, class_name: "Logs::Link", foreign_key: :log_entry_id,
             inverse_of: :log_entry, dependent: :destroy

    enum :level, { debug: 0, info: 1, warning: 2, error: 3, fatal: 4 }, prefix: true

    validates :event_id, presence: true, uniqueness: { scope: :project_id }
    validates :message, presence: true
    validates :occurred_at, presence: true

    # Stream reverse-cronologico (tie-break su id per cursore stabile).
    scope :recent, -> { order(occurred_at: :desc, id: :desc) }
  end
end
