# frozen_string_literal: true

# CYSK-26 — l'estratto di copertura così come la CI l'ha pubblicato, più i contatori di testata.
class CoverageReportSerializer < ApplicationSerializer
  attributes :id, :branch, :sha, :captured_at, :line_covered_percent, :branch_covered_percent,
             :files_count, :never_loaded_count, :payload, :updated_at
end
