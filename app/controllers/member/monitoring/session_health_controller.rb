# frozen_string_literal: true

module Member
  module Monitoring
    class SessionHealthController < Member::BaseController
      permission_not_required "Session health is read-only and scoped to visible projects.", only: :index
      include Indexable

      DEFAULT_RANGE = "7d"
      FACET_LIMIT = 200
      monitoring_time_range
      remembers_filters :project_id, :environment, :source, :q, :sort, only: :index

      def index
        sessions = ::SessionHealth::Session.where(project_id: visible.projects.select(:id))
        aggregates = ::SessionHealth::Aggregate.where(project_id: visible.projects.select(:id))
        @has_records = sessions.exists? || aggregates.exists?
        load_facets(sessions, aggregates)
        source = params[:source].presence_in(%w[individual aggregate])
        @pagination = ::SessionHealth::Query.new(sessions: filtered(sessions), aggregates: filtered(aggregates), source: source)
          .call(page: params[:page], per: requested_per(Pagination::DEFAULT_PER), sort: params[:sort])
        @rows = @pagination.records
        @row_projects = visible.projects.where(id: @rows.map { |row| row.fetch("project_id") }).index_by(&:id)
      end

      private

      def current_time_range
        @current_time_range ||= ::Monitoring::TimeRange.resolve(key: params[:range].presence || DEFAULT_RANGE, from: params[:from], to: params[:to])
      end

      def filtered(scope)
        scope = filter_by_project(scope)
        scope = scope.where(environment: filter_ids(:environment)) if filter_ids(:environment).any?
        scope = scope.where("release ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(search_q)}%") if search_q.present?
        current_time_range.apply(scope, column: :started_at)
      end

      def prioritized(scope, column, selected)
        selected.empty? ? scope : scope.in_order_of(column, selected.take(FACET_LIMIT), filter: false)
      end

      def load_facets(sessions, aggregates)
        @projects = prioritized(visible.projects, :id, filter_ids(:project_id)).order(:name, :id).limit(FACET_LIMIT).to_a
        environments = [ sessions, aggregates ].map do |scope|
          prioritized(scope.where.not(environment: nil).group(:environment), :environment, filter_ids(:environment))
            .order(:environment).limit(FACET_LIMIT).pluck(:environment)
        end
        values = environments.flatten.uniq
        @environments = ((filter_ids(:environment) & values) + values.sort).uniq.take(FACET_LIMIT)
      end
    end
  end
end
