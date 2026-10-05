# frozen_string_literal: true

module Seo
  # Un giro di prova sulla velocità di un sito (CYRA-539): PageSpeed Insights misura la home su un
  # telefono e su un computer, e questa riga conserva quello che ha detto.
  #
  # Storicizzata, non «solo l'ultimo»: il valore di una misura di velocità è la tendenza — è
  # peggiorato dopo il rilascio di giovedì? — e un singolo numero non risponde a quella domanda.
  # L'ultimo buono si prende con `completed.for(strategy).recent.first`, che l'indice copre.
  #
  # Un giro fallito resta in elenco col suo motivo e NON tocca la riga riuscita precedente: la
  # scheda mostra i numeri buoni di prima dicendo che sono vecchi. È la stessa decisione già presa
  # per i giri di visita (`Seo::Audit`): quello che non si è visto non si dichiara risolto.
  class LabRun < ApplicationRecord
    self.table_name = "seo_lab_runs"

    belongs_to :site, class_name: "Seo::Site", inverse_of: :lab_runs

    # Sono le due strategie dell'API, non un'invenzione nostra. Mobile è 0 perché è quella con cui
    # Google indicizza: se se ne guarda una sola, è quella.
    enum :strategy, { mobile: 0, desktop: 1 }, prefix: :on
    enum :status, { running: 0, completed: 1, failed: 2 }, prefix: :status

    validates :url, presence: true
    validates :started_at, presence: true

    scope :recent, -> { order(started_at: :desc) }
    scope :for_strategy, ->(strategy) { where(strategy:) }

    # L'ultimo giro RIUSCITO per una strategia. Un giro fallito non sostituisce mai i numeri buoni.
    def self.last_completed(strategy) = status_completed.for_strategy(strategy).recent.first

    def duration_seconds
      return nil if started_at.blank? || finished_at.blank?

      (finished_at - started_at).round
    end

    # Le misure di laboratorio, nell'ordine in cui si leggono, con la sigla che le identifica: la
    # vista non deve conoscere i nomi delle colonne per disegnare una riga di misure.
    def lab_metrics
      { "lcp" => lab_lcp_ms, "cls" => lab_cls&.to_f, "tbt" => lab_tbt_ms,
        "fcp" => lab_fcp_ms, "ttfb" => lab_ttfb_ms, "speed_index" => lab_speed_index_ms }
    end

    # Le misure di campo che Google ha su questa URL (o sull'origine, vedi `field_origin_fallback`).
    def field_metrics
      { "lcp" => field_lcp_ms, "inp" => field_inp_ms, "cls" => field_cls&.to_f,
        "fcp" => field_fcp_ms, "ttfb" => field_ttfb_ms }
    end

    # Google ha abbastanza dati da dire qualcosa? Se no, la pagina lo scrive invece di mostrare una
    # fila di trattini che sembra un guasto nostro.
    def field?
      field_metrics.values.any?(&:present?)
    end

    def scores
      { "performance" => performance_score, "accessibility" => accessibility_score,
        "best_practices" => best_practices_score, "seo" => seo_score }
    end
  end
end
