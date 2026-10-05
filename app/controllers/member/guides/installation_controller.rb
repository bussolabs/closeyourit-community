# frozen_string_literal: true

module Member
  module Guides
    class InstallationController < Member::BaseController
      PROJECT_LIMIT = 200
      OBSERVATION_LIMIT = 100

      permission_not_required "Installation guidance and receipt metadata are read-only within visible projects.", only: %i[show receipt]
      rescue_from ::Guides::Installation::Invalid, with: :invalid_selection
      rescue_from ::Guides::Installation::Unavailable, with: :unavailable
      before_action :validate_project_parameters
      before_action :load_selection

      def show
        @project_query = params[:project_query].to_s.strip
        raise ::Guides::Installation::Invalid, "Project search is too long" if @project_query.length > 100
        projects = visible.projects
        if @project_query.present?
          query = "%#{ApplicationRecord.sanitize_sql_like(@project_query)}%"
          projects = projects.where("projects.name ILIKE :query OR projects.key ILIKE :query", query: query)
        end
        @projects = projects.order(:name, :id).limit(PROJECT_LIMIT).to_a
        @project = params[:project_id].present? ? visible.projects.find(params[:project_id]) : @projects.first
        @projects.unshift(@project) if @project && @projects.none? { |project| project.id == @project.id }
        @choices = @records.first(OBSERVATION_LIMIT)
        @choices.unshift(@candidate) if @candidate && @choices.none? { |row| row["run_id"] == @candidate["run_id"] }
        @public_configuration = ::Guides::Installation::PublicConfiguration.call(project: @project, actor: Current.account,
          organization: Current.organization, observation: @observation, host: request.host_with_port, environment: params[:environment]) if @observation
        @history_page = Pagination.from_array(@records, page: params[:page], per: params[:per])
        @history = @history_page.records
        @recipe = ::Guides::Installation::Recipe.call(observation: @observation) if @observation
        content = render_to_string(:show, layout: "member")
        raise ::Guides::Installation::Unavailable, "Guide response budget exceeded" if content.bytesize > 1.megabyte
        render html: content.html_safe
      end

      def receipt
        raise ::Guides::Installation::Invalid, "Select an observed version" unless @observation && params[:run_id].present?
        project = visible.projects.find(params[:project_id])
        data = ::Guides::Installation::Receipt.call(project: project, observation: @observation,
          parameters: params.permit(:event_id, :trace_id, :span_id, :environment, :release, :from, :to).to_h)
        render json: { data: data }
      rescue ActiveRecord::RecordNotFound
        render_problem(:not_found, "not_found")
      end

      private

      def validate_project_parameters
        %i[project_id project_query].each do |key|
          value = params[key]
          unless value.nil? || value.is_a?(String)
            raise ::Guides::Installation::Invalid, "Project parameters must be scalar strings"
          end
        end
        if action_name == "receipt" && params[:project_id].blank?
          raise ::Guides::Installation::Invalid, "A receipt project is required"
        end
      end

      def load_selection
        @records = ::Guides::Installation::Catalog.call
        @candidate = ::Guides::Installation::Selection.call(records: @records, run_id: params[:run_id])
        @observation = ::Guides::Installation::Selection.call(records: @records, run_id: params[:run_id], version: params[:version])
        @signal = @observation&.dig("tuple", "integration") == "php-laravel-otlp" ? "traces" : "errors"
      end

      def invalid_selection
        render_problem(:unprocessable_content, "invalid")
      end

      def unavailable
        render_problem(:service_unavailable, "unavailable")
      end

      def render_problem(status, reason)
        if action_name == "receipt" || request.format.json?
          render json: { error: { code: "installation_#{reason}", message: t("member.installation.#{reason}") } }, status: status
        else
          @problem = reason
          render :problem, status: status
        end
      end
    end
  end
end
