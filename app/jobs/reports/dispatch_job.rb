# frozen_string_literal: true

module Reports
  # Giro giornaliero che chiede chi deve ricevere il riepilogo dei dati (CYRA-160). La cadenza vera
  # non sta qui ma nella preferenza di ciascuno (giornaliera, settimanale dal lunedì, mensile dal
  # primo): questo giro si limita a domandare «tocca a te?» e a isolare ogni invio in un job suo,
  # come Seo::DispatchAuditsJob e Uptime::DispatchChecksJob.
  #
  # Solo chi ha acceso la frequenza entra nella query: l'elenco è corto per costruzione (OFF è il
  # default), quindi il giro costa una scansione di poche righe anche con molte organizzazioni.
  class DispatchJob < ApplicationJob
    queue_as :notifications

    def perform
      Alerting::Preference.where.not(report_cadence: :off).find_each do |preference|
        Reports::DeliverJob.perform_later(preference.id) if preference.report_due?
      end
    end
  end
end
