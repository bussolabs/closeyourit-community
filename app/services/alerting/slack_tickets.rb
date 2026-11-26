# frozen_string_literal: true

module Alerting
  # The alerts that «Apri ticket» can turn into a ticket from Slack: same permission and same service as
  # their page. Any other alert gets a button to its page instead. CYRA-1156
  module SlackTickets
    Entry = Data.define(:permission, :promote)

    REGISTRY = {
      "Errors::Group" => Entry.new(permission: "errors.promote",
                                   promote: ->(subject, account) { Errors::PromoteToTicket.call(group: subject, reporter: account) }),
      "Metrics::Group" => Entry.new(permission: "metrics.promote",
                                    promote: ->(subject, account) { Metrics::PromoteToTicket.call(group: subject, reporter: account) }),
      "Logs::Entry" => Entry.new(permission: "logs.link",
                                 promote: ->(subject, account) { Logs::PromoteToTicket.call(entry: subject, reporter: account) }),
      "Vulnerabilities::Finding" => Entry.new(permission: "vulnerabilities.triage",
                                              promote: ->(subject, account) { Vulnerabilities::PromoteToTicket.call(group: subject, reporter: account) }),
      "Seo::Issue" => Entry.new(permission: "seo.triage",
                                promote: ->(subject, account) { Seo::PromoteToTicket.call(issue: subject, reporter: account) })
    }.freeze

    def self.supported?(subject_type) = REGISTRY.key?(subject_type.to_s)

    def self.for(subject_type) = REGISTRY[subject_type.to_s]

    # The ticket after a promotion: a log answers with it, a group already promoted keeps it.
    def self.ticket_of(result, subject)
      value = result.ok? ? result.value : nil
      value = value.ticket if value.respond_to?(:reused)
      value ||= subject.ticket if subject.respond_to?(:ticket)
      value.is_a?(Ticketing::Ticket) ? value : nil
    end
  end
end
