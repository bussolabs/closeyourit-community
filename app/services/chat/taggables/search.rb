# frozen_string_literal: true

module Chat
  module Taggables
    # Alimenta l'autocomplete del picker di risorse taggabili: cerca risorse che RIENTRANO
    # nell'intersezione delle visibilità dei partecipanti della conversazione ("in comune"), filtrate
    # per query e (opzionale) tipo. È il primo dei due livelli di difesa anti-BOLA — PostMessage
    # rivalida al salvataggio. Ritorna Array<Hash> pronto per il JSON del picker (helper, non Result).
    # I log non compaiono in autocomplete (stream senza titolo): si taggano col token cyi:log:<id>.
    class Search < ApplicationService
      LIMIT = 8

      def initialize(conversation:, query: nil, type: nil)
        @conversation = conversation
        @query = query.to_s.strip
        @type = type.presence
      end

      def call
        project_ids = common_project_ids
        return [] if project_ids.empty?

        results = []
        results.concat(tickets(project_ids)) if want?("ticket")
        results.concat(projects(project_ids)) if want?("project")
        results.concat(error_groups(project_ids)) if want?("error")
        results.concat(metric_groups(project_ids)) if want?("metric")
        results.concat(monitors(project_ids)) if want?("uptime")
        results.first(LIMIT)
      end

      private

      def common_project_ids
        Chat::CommonScope.new(accounts: @conversation.audience, organization: @conversation.organization).project_ids
      end

      def want?(type)
        @type.nil? || @type == type
      end

      def like
        "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      end

      def tickets(project_ids)
        Ticketing::Ticket.where(project_id: project_ids)
                         .where("title ILIKE ?", like).order(created_at: :desc).limit(LIMIT)
                         .map { |ticket| entry("ticket", ticket.id, "##{ticket.code}", ticket.title, ticket.code) }
      end

      def projects(project_ids)
        Projects::Project.where(id: project_ids)
                         .where("name ILIKE ? OR key ILIKE ?", like, like).order(:name).limit(LIMIT)
                         .map { |project| entry("project", project.id, "cyi:project:#{project.id}", project.name, project.key) }
      end

      def error_groups(project_ids)
        Errors::Group.where(project_id: project_ids)
                     .where("title ILIKE ?", like).order(last_seen_at: :desc).limit(LIMIT)
                     .map { |group| entry("error", group.id, "cyi:error:#{group.id}", group.title, "error") }
      end

      def metric_groups(project_ids)
        Metrics::Group.where(project_id: project_ids)
                      .where("title ILIKE ?", like).order(created_at: :desc).limit(LIMIT)
                      .map { |group| entry("metric", group.id, "cyi:metric:#{group.id}", group.title, "performance") }
      end

      def monitors(project_ids)
        Uptime::Monitor.where(project_id: project_ids)
                       .where("name ILIKE ?", like).order(:name).limit(LIMIT)
                       .map { |monitor| entry("uptime", monitor.id, "cyi:uptime:#{monitor.id}", monitor.name, "uptime") }
      end

      def entry(type, id, token, label, hint)
        { type: type, id: id, token: token, label: label.to_s, hint: hint.to_s }
      end
    end
  end
end
