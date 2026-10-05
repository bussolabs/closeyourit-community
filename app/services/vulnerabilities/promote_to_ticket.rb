# frozen_string_literal: true

module Vulnerabilities
  # Promuove una vulnerabilità a ticket. Specializza Observability::PromoteToTicket, che porta già
  # l'idempotenza sotto concorrenza (`with_lock` + re-check) — la stessa che serve qui, perché la
  # promozione può arrivare sia da una persona sia dalla scansione notturna.
  #
  # La base chiama il parametro `group:`: qui il "gruppo" è il finding. Il nome resta quello per non
  # duplicare la base, che è il pezzo che garantisce il doppio-submit = un ticket solo.
  class PromoteToTicket < Observability::PromoteToTicket
    private

    def already_promoted_code = "R422-VULN-001"

    def ticket_params
      {
        project_id: @group.project_id,
        title: title,
        technical_analysis: technical_details,
        scenarios_attributes: [ {
          step_given: "Reported from dependency scanning.",
          step_when: "#{@group.package_coordinates} is resolved in #{manifest.path}",
          step_then: @group.advisory.summary.presence || "A known vulnerability affects this version.",
          step_expected: expected_step
        } ],
        status_id: default_status&.id,
        priority_id: default_priority&.id
      }
    end

    # Il titolo è la sola parte che un non tecnico legge in lista: gravità, cosa e dove.
    def title
      I18n.t("member.monitoring.vulnerabilities.ticket_title",
             severity: I18n.t("member.monitoring.vulnerabilities.severity.#{@group.severity}"),
             package: @group.package_coordinates,
             advisory: @group.display_id).truncate(255)
    end

    def expected_step
      return "The dependency is updated to #{@group.fixed_version}." if @group.fixable?

      "The dependency is replaced or removed: no fixed version exists yet."
    end

    def technical_details
      parts = [
        "Advisory: #{@group.advisory.osv_id}",
        ("Aliases: #{@group.advisory.aliases.join(', ')}" if @group.advisory.aliases.any?),
        "Severity: #{@group.severity}",
        ("CVSS: #{@group.advisory.cvss}" if @group.advisory.cvss.present?),
        ("CWE: #{@group.advisory.cwe_ids.join(', ')}" if @group.advisory.cwe_ids.any?),
        "Package: #{@group.package_coordinates} (#{@group.package_ecosystem})",
        "Manifest: #{manifest.path}",
        "Direct dependency: #{@group.package.direct? ? 'yes' : 'no'}",
        ("Fixed in: #{@group.fixed_version}" if @group.fixable?),
        "Reference: #{@group.advisory.osv_url}"
      ].compact

      # Il testo dell'advisory viene da un database esterno e non ha tetto: troncare tutto insieme al
      # limite del campo evita che una descrizione fluviale faccia fallire la creazione del ticket.
      parts.join("\n").truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end

    def manifest = @group.package.manifest
  end
end
