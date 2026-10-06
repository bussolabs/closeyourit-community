# frozen_string_literal: true

module Agents
  module Supporters
    # CYAU-235 — the topics the supporter never decides alone: the built-in ones, plus those the organization
    # and the project add. Lists only add up: a project cannot remove what the organization or the built-in
    # list reserve. Matching is by whole word, or by path prefix for an entry that holds a slash. A match can
    # only send more to a person, so over-matching is the safe mistake.
    class ReservedTopics
      Entry = Data.define(:value, :source, :topic) do
        def path? = value.include?("/")
      end

      BUILT_IN = {
        "money" => %w[price prices pricing prezzo prezzi payment payments pagamento pagamenti vat iva invoice invoices
                      fattura fatture billing refund refunds rimborso rimborsi discount sconto],
        "security" => %w[password passwords secret secrets segreto segreti credential credentials credenziali token tokens
                         permission permissions permessi authentication autenticazione authorization],
        "personal_data" => [ "gdpr", "personal data", "dati personali", "privacy" ],
        "data_deletion" => [ "delete data", "cancellare dati", "cancella i dati", "purge", "truncate", "drop table" ],
        "customer_visible" => [ "customer-facing", "visible to customers", "visibile ai clienti", "email to customers",
                                "email ai clienti" ]
      }.freeze

      def initialize(organization:, project: nil)
        @organization = organization
        @project = project
      end

      def entries
        @entries ||= (built_in + listed(organization_topics, :organization) + listed(project&.supporter_reserved_topic_list, :project))
          .uniq(&:value)
      end

      # The entries the text or the touched paths hit; empty when none.
      def match(text:, paths: [])
        clean_paths = paths.map { |path| path.to_s.downcase.delete_prefix("./").delete_prefix("/") }
        entries.select do |entry|
          entry.path? ? clean_paths.any? { |path| path.start_with?(entry.value) } : word?(text.to_s, entry.value)
        end
      end

      private

      attr_reader :organization, :project

      def built_in = BUILT_IN.flat_map { |topic, words| words.map { |word| Entry.new(value: word, source: :built_in, topic: topic) } }

      def listed(values, source) = Array(values).map { |value| Entry.new(value: value, source: source, topic: nil) }

      def organization_topics = AutomatorSetting.find_by(organization: organization)&.supporter_reserved_topic_list

      def word?(text, value) = text.match?(/(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/i)
    end
  end
end
