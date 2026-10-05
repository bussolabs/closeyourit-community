# frozen_string_literal: true

module Seo
  # Cosa succede DOPO che il giro ha scritto i rilievi nuovi: l'avviso a chi di dovere.
  #
  # Solo i rilievi GRAVI, e solo quelli NUOVI. Un cockpit che avvisa a ogni immagine senza
  # descrizione insegna a ignorare i suoi avvisi, e allora tace anche il giorno che la home passa
  # `noindex`. Il resto si guarda dalla pagina, che è lì apposta.
  #
  # Separato dalla scrittura di proposito: i rilievi devono finire nel database anche se l'alerting
  # è configurato male, e questo pezzo si prova senza toccare la rete.
  class NotifyIssues < ApplicationService
    # La soglia dell'interruzione: sotto, è materiale da leggere quando si ha tempo.
    NOTIFIABLE_SEVERITIES = %w[high critical].freeze

    def initialize(issues:)
      @issues = Array(issues)
    end

    def call
      notifiable = @issues.select { |issue| NOTIFIABLE_SEVERITIES.include?(issue.severity.to_s) }
      notifiable.each { |issue| enqueue_alert(issue) }

      Result.ok(notifiable.size)
    end

    private

    def enqueue_alert(issue)
      Alerting::EvaluateJob.perform_later(
        event_type: "seo_issue_new",
        subject_type: "Seo::Issue",
        subject_id: issue.id,
        project_id: issue.site.project_id,
        environment_id: issue.site.environment_id
      )
    end
  end
end
