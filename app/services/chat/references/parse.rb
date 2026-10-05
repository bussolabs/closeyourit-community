# frozen_string_literal: true

module Chat
  module References
    # Estrae le risorse taggate nel testo di un messaggio e le RISTRINGE all'intersezione delle
    # visibilità dei partecipanti (CommonScope) — è il cuore del vincolo "risorse che tutti vedono in
    # comune". Token supportati:
    #   - #KEY-NUMERO  → ticket (es. #PROJ-123), risolto per progetto+numero nell'org
    #   - cyi:<tipo>:<uuid> → project/ticket/error/metric/log/uptime
    # Filosofia gemella di Ticketing::Mentions::Parse: ritorna Array<record> (helper, non Result); il
    # chiamante persiste i Chat::MessageReference. Deduplicato per (classe, id).
    class Parse < ApplicationService
      # #KEY-NUMERO — KEY = project key (≤4, alfanumerico), lookbehind anti-parola/anti-trattino.
      CODE = /(?<![\w-])#([A-Z0-9]{1,4})-(\d+)\b/i
      # cyi:tipo:uuid
      TOKEN = /\bcyi:(project|ticket|error|metric|log|uptime):([0-9a-fA-F-]{36})\b/
      TYPES = {
        "project" => "Projects::Project", "ticket" => "Ticketing::Ticket",
        "error" => "Errors::Group", "metric" => "Metrics::Group",
        "log" => "Logs::Entry", "uptime" => "Uptime::Monitor"
      }.freeze

      def initialize(text:, organization:, participants:)
        @text = text.to_s
        @organization = organization
        @participants = Array(participants)
      end

      def call
        candidates = (tickets_by_code + tokenized).uniq { |record| [ record.class.name, record.id ] }
        # Short-circuit: senza tag nel testo niente calcolo CommonScope (che costa O(audience) query).
        return [] if candidates.empty?

        common = common_project_ids
        candidates.select { |record| common.include?(project_id_of(record)) }
      end

      private

      def common_project_ids
        Chat::CommonScope.new(accounts: @participants, organization: @organization).project_ids
      end

      # #KEY-NUMERO → progetto per key nell'org, poi ticket per numero.
      def tickets_by_code
        @text.scan(CODE).filter_map do |key, number|
          project = Projects::Project.find_by(organization_id: @organization.id, key: key.upcase)
          next if project.nil?

          Ticketing::Ticket.find_by(project_id: project.id, number: number)
        end
      end

      # cyi:tipo:uuid → record per tipo whitelisted, scartato subito se di un'altra org (difesa in
      # profondità: l'intersezione progetti a valle filtra già, ma il lookup non deve MAI portare
      # in memoria record cross-tenant per UUID noti/indovinati).
      def tokenized
        @text.scan(TOKEN).filter_map do |type, id|
          record = TYPES[type.downcase].constantize.find_by(id: id)
          record if record && organization_id_of(record) == @organization.id
        end
      end

      # Il project_id su cui poggia la visibilità: il Project è sé stesso, gli altri lo denormalizzano.
      def project_id_of(record)
        record.is_a?(Projects::Project) ? record.id : record.try(:project_id)
      end

      # L'org del record: il Project la porta diretta, le altre risorse la raggiungono via project.
      def organization_id_of(record)
        record.is_a?(Projects::Project) ? record.organization_id : record.try(:project)&.organization_id
      end
    end
  end
end
