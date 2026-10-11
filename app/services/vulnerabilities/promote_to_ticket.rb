# frozen_string_literal: true

module Vulnerabilities
  # Promuove una vulnerabilità a ticket. Specializza Observability::PromoteToTicket, che porta già
  # l'idempotenza sotto concorrenza (`with_lock` + re-check) — la stessa che serve qui, perché la
  # promozione può arrivare sia da una persona sia dalla scansione notturna.
  #
  # La base chiama il parametro `group:`: qui il "gruppo" è il finding. Il nome resta quello per non
  # duplicare la base, che è il pezzo che garantisce il doppio-submit = un ticket solo.
  class PromoteToTicket < Observability::PromoteToTicket
    # CYRA-1075 — one package, one open ticket: a later advisory is named on it instead of opening a
    # twin. Not linked as its finding: the schema keeps one finding per ticket.
    def call
      return already_promoted if @group.promoted?

      open_ticket = open_ticket_for_package
      return super if open_ticket.nil?

      unless open_ticket.comments.where("body LIKE ?", "%#{@group.advisory.display_id}%").exists?
        Ticketing::AddComment.call(ticket: open_ticket, author: @reporter,
                                   params: { body: joined_comment.truncate(Ticketing::Constants::COMMENT_MAX_CHARS) })
      end
      Result.ok(open_ticket)
    end

    private

    def open_ticket_for_package
      Vulnerabilities::Finding.joins(:package, ticket: :status)
                              .where(project_id: @group.project_id)
                              .where(vulnerabilities_packages: { name: @group.package.name,
                                                                 ecosystem: @group.package.ecosystem })
                              .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories.fetch("done") })
                              .first&.ticket
    end

    def joined_comment
      fix = @group.fixable? ? " Corretta in #{@group.fixed_version}." : ""
      "Stessa libreria, nuova falla: #{@group.advisory.display_id} (#{@group.severity}).#{fix} " \
        "Va chiusa con la stessa correzione di questo ticket."
    end

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
