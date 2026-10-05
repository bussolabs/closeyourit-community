# frozen_string_literal: true

module Member
  module Monitoring
    class MeasurementRulesController < Member::BaseController
      include Member::MeasurementReading
      include Indexable
      permission_not_required "Reading measurement rules is scoped to visible projects.", only: %i[index show]
      before_action -> { require_permission!("alerts.manage") }, except: %i[index show]
      before_action :set_rule, only: %i[show edit update destroy]
      remembers_filters :q, :sort, only: :index
      SORT_COLUMNS = { "name" => "LOWER(alerting_rules.name)", "enabled" => :enabled, "updated" => :updated_at }.freeze

      def index
        @saved_views = bounded_records(saved_views_for("measurement_rules").limit(100))
        @has_records = rule_scope.exists?
        scope = rule_scope.order(:name, :id)
        scope = scope.where("name ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(search_q)}%") if search_q.present?
        @pagination = page_records(sorted(scope, columns: SORT_COLUMNS).order(id: :desc))
        @rules = @pagination.records
        @row_projects = visible.projects.where(id: @rules.map(&:project_id)).index_by(&:id)
        measurement_page
      end

      def show
        @series = bounded_records(measurement_scope.where(id: @rule.measurement_series_id).limit(1)).first
        @project = visible.projects.find(@rule.project_id)
        @channels = bounded_records(@rule.channels.order(:name).limit(200))
        @pagination = page_records(::Alerting::Evaluation.where(project_id: @rule.project_id, rule_id: @rule.id).order(window_end_ns: :desc, created_at: :desc, id: :desc))
        @latest = bounded_records(::Alerting::Evaluation.where(project_id: @rule.project_id, rule_id: @rule.id).order(window_end_ns: :desc, created_at: :desc, id: :desc).limit(1)).first
        @current_digest = ::Alerting::Measurements::Configuration.digest(@rule)
        measurement_page
      end

      def new
        @rule = Current.organization.alerting_rules.new(event_type: :measurement_threshold, enabled: true, throttle_seconds: 300,
          measurement_config: { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "0", "window_seconds" => 60 })
        load_form
        measurement_page
      end

      def edit
        load_form
        measurement_page
      end

      def create
        @rule = Current.organization.alerting_rules.new(event_type: :measurement_threshold)
        save_rule(:new)
      end

      def update
        save_rule(:edit)
      end

      def destroy
        return head :unprocessable_content unless params[:confirm] == "1"
        @rule.destroy!
        redirect_to member_monitoring_measurement_rules_path, notice: t("member.measurements.deleted")
      end

      private

      def rule_scope
        Current.organization.alerting_rules.where(event_type: :measurement_threshold, project_id: visible.projects.select(:id))
      end

      def set_rule
        @rule = bounded_record(rule_scope.where(id: params[:id]))
      end

      def load_form
        @form = @rule.measurement_config.merge("name" => @rule.name, "project_id" => @rule.project_id,
          "measurement_series_id" => @rule.measurement_series_id, "throttle_seconds" => @rule.throttle_seconds,
          "enabled" => @rule.enabled? ? "1" : "0", "channel_ids" => @rule.channel_ids).merge(params.permit(:name, :project_id, :measurement_series_id, :statistic, :comparison, :threshold, :window_seconds, :quantile, :throttle_seconds, :enabled, channel_ids: []).to_h)
        @projects = visible.projects.order(:name, :id).limit(200).to_a
        @projects |= visible.projects.where(id: @form["project_id"]).limit(1).to_a
        scope = measurement_scope.where(project_id: @form["project_id"])
        scope = scope.where("name ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(params[:series_q].to_s)}%") if params[:series_q].present?
        @choices = bounded_records(scope.order(:name, :id).limit(100))
        @series = bounded_records(measurement_scope.where(project_id: @form["project_id"], id: @form["measurement_series_id"]).limit(1)).first
        @choices |= [ @series ].compact
        @form["statistic"] = ::Alerting::Measurements::Configuration::STATISTICS.fetch(@series.metric_type).first if @series && @rule.new_record? && params[:statistic].blank?
        @channels = bounded_records(Current.organization.alerting_channels.order(:name, :id).limit(200))
        @channels |= bounded_records(Current.organization.alerting_channels.where(id: Array(@form["channel_ids"]).first(200)))
      end

      def save_rule(template)
        result = ::Alerting::Rules::Save.call(rule: @rule, organization: Current.organization, actor: Current.account, attributes: rule_attributes)
        if result.ok?
          redirect_to member_monitoring_measurement_rule_path(@rule), notice: t("member.measurements.saved")
        else
          @invalid = true
          load_form
          measurement_page(template, status: :unprocessable_content)
        end
      rescue ArgumentError, TypeError
        @invalid = true
        load_form
        measurement_page(template, status: :unprocessable_content)
      end

      def rule_attributes
        allowed = params.permit(:name, :project_id, :measurement_series_id, :enabled, channel_ids: []).to_h
        raise ArgumentError unless %w[0 1].include?(allowed["enabled"])
        config = params.permit(:statistic, :comparison, :threshold, :quantile).to_h
        config.delete("quantile") unless config["statistic"] == "percentile"
        config.merge!("version" => 1, "window_seconds" => strict_integer(params[:window_seconds]))
        allowed.merge("event_type" => "measurement_threshold", "enabled" => allowed["enabled"] == "1",
          "measurement_config" => config, "throttle_seconds" => strict_integer(params[:throttle_seconds]),
          "channel_ids" => Array(allowed["channel_ids"]))
      end

      def strict_integer(value)
        raise ArgumentError unless value.is_a?(String) && value.match?(/\A\d{1,9}\z/)
        Integer(value, 10)
      end
    end
  end
end
