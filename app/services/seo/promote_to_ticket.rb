# frozen_string_literal: true

module Seo
  # Promuove un rilievo SEO a ticket. Specializza Observability::PromoteToTicket, che porta già
  # l'idempotenza sotto concorrenza (`with_lock` + re-check): doppio click uguale un ticket solo.
  #
  # La base chiama il parametro `group:`; qui il "gruppo" è il rilievo. Il nome resta quello per non
  # duplicare la base, che è il pezzo che garantisce l'idempotenza.
  class PromoteToTicket < Observability::PromoteToTicket
    def initialize(issue:, reporter:, true_actor: nil)
      super(group: issue, reporter:, true_actor:)
    end

    private

    def already_promoted_code = "R422-SEO-001"

    def ticket_params
      {
        project_id: @group.site.project_id,
        title: title,
        technical_analysis: technical_details,
        scenarios_attributes: [ {
          step_given: "Rilevato dal controllo SEO del sito #{@group.site.base_url}.",
          step_when: "Si apre #{@group.url}",
          step_then: @group.explanation.presence || @group.label,
          step_expected: expected_step
        } ],
        status_id: default_status&.id,
        priority_id: default_priority&.id
      }
    end

    # Il titolo è la sola parte che un non tecnico legge in lista: cosa non va e dove.
    def title
      I18n.t("member.monitoring.seo.ticket_title", check: @group.label, url: short_url).truncate(255)
    end

    def expected_step
      I18n.t("seo.checks.#{@group.check_key}.expected",
             default: I18n.t("member.monitoring.seo.ticket_expected_fallback"))
    end

    # La prova, così com'è stata raccolta: chi apre il ticket deve poter verificare senza rifare
    # l'analisi a mano.
    def technical_details
      parts = [
        "Controllo: #{@group.check_key} (#{@group.area})",
        "Gravità: #{@group.severity}",
        "URL: #{@group.url}",
        "Sito: #{@group.site.base_url} (#{@group.site.environment.label})",
        "Prima visto: #{@group.first_seen_at.iso8601}",
        "Ultimo controllo: #{@group.last_seen_at.iso8601}",
        "Prova: #{@group.evidence.to_json}"
      ]

      parts.join("\n").truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end

    def short_url
      URI.parse(@group.url.to_s).request_uri
    rescue URI::InvalidURIError, NoMethodError
      @group.url.to_s
    end
  end
end
