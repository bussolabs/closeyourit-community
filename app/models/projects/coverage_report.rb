# frozen_string_literal: true

module Projects
  # CYSK-26 — l'estratto di copertura pubblicato dalla CI (branch di default): per file righe e rami
  # percorsi (più `never_loaded` dai tracked_files), per ogni ramo mai preso la posizione e gli hit
  # della condizione padre, e i metadati della run. Una riga per [progetto, branch], upsert: qui vive
  # l'ULTIMA fotografia, non lo storico — è il dato su cui lo scanner del codice non usato decide se
  # la misura è credibile prima di fidarsene.
  class CoverageReport < ApplicationRecord
    self.table_name = "projects_coverage_reports"

    # Tetto sul payload: l'estratto misurato del repo più grosso è ~105 KB gzippato; un megabyte di
    # jsonb è già dieci volte tanto. Oltre, sta arrivando il resultset intero — che non è il canale.
    MAX_PAYLOAD_BYTES = 2 * 1024 * 1024

    belongs_to :project, class_name: "Projects::Project", inverse_of: :coverage_reports

    normalizes :branch, with: ->(value) { value.to_s.strip }

    validates :branch, presence: true, uniqueness: { scope: :project_id }
    validates :captured_at, presence: true
    validate :payload_within_limit

    private

    def payload_within_limit
      return if payload.blank?
      return if payload.to_json.bytesize <= MAX_PAYLOAD_BYTES

      errors.add(:payload, "supera il tetto di #{MAX_PAYLOAD_BYTES / 1024} KB: pubblica l'estratto, non il resultset intero")
    end
  end
end
