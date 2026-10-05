# frozen_string_literal: true

module Alerting
  module Rules
    # Crea o aggiorna una regola di alerting: attributi base + scope org (project/environment).
    # Service di dominio CONDIVISO da Member e Cli (`rules/backend-channels.md`) — la logica vive qui sola.
    # La conversione throttle_minutes→throttle_seconds NON è qui: la fa il controller del canale, che passa
    # già gli attributi canonici (name, event_type, min_level, threshold_ms, throttle_seconds, enabled).
    # Anti-BOLA: project_id/environment_id accettati solo se appartengono all'org (id di altra org → nil).
    class Save < ApplicationService
      def initialize(rule:, organization:, attributes:, actor: nil)
        @rule = rule
        @organization = organization
        @attributes = attributes.to_h.symbolize_keys
        @actor = actor
      end

      def call
        @rule.class.transaction do
          @rule.lock! if @rule.persisted?
          save_attributes
        end
      rescue ActiveRecord::RecordInvalid => error
        Result.err(AppError.new(error.record.errors.full_messages.to_sentence,
          code: "R422-ALERT-001", status: :unprocessable_content, details: error.record.errors.to_hash))
      end

      private

      def save_attributes
        if @rule.persisted? && @rule.event_measurement_threshold? &&
            !Authorization::VisibleScope.new(account: @actor, organization: @organization).projects.exists?(id: @rule.project_id)
          @rule.errors.add(:project_id, "must identify an accessible project")
          raise ActiveRecord::RecordInvalid, @rule
        end
        measurement = (@attributes[:event_type] || @rule.event_type).to_s == "measurement_threshold"
        validate_measurement_scope! if measurement
        @rule.assign_attributes(@attributes.except(:project_id, :environment_id, :channel_ids))
        # Scope: come channel_ids qui sotto, chiave assente → non toccare (CYCL-62). Assegnarlo sempre
        # rendeva org-wide una regola di progetto a ogni update parziale della CLI.
        if @attributes.key?(:project_id)
          @rule.project_id = scoped_id(@organization.projects, @attributes[:project_id])
        end
        if @attributes.key?(:environment_id)
          @rule.environment_id = scoped_id(@organization.environments, @attributes[:environment_id])
        end
        # Canali esterni: SET completo, scoped all'org (id altrui cadono). Chiave assente → non toccare.
        if @attributes.key?(:channel_ids)
          ids = Array(@attributes[:channel_ids]).reject(&:blank?)
          @rule.channel_ids = @organization.alerting_channels.where(id: ids).ids
        end
        @rule.created_by ||= @actor if @rule.new_record?

        @rule.save!
        Result.ok(@rule)
      end

      def validate_measurement_scope!
        project_id = @attributes.fetch(:project_id, @rule.project_id)
        series_id = @attributes.fetch(:measurement_series_id, @rule.measurement_series_id)
        visible = Authorization::VisibleScope.new(account: @actor, organization: @organization).projects
        valid_project = visible.exists?(id: project_id)
        unavailable = @rule.persisted? && series_id.nil? && (@attributes.keys & %i[project_id measurement_series_id measurement_config]).empty?
        valid_series = valid_project && (unavailable || ::Measurements::Series.exists?(id: series_id, project_id: project_id))
        unless valid_series
          @rule.errors.add(:measurement_series_id, "must identify an accessible series in the selected project")
          raise ActiveRecord::RecordInvalid, @rule
        end
        return unless @attributes.key?(:channel_ids)
        ids = Array(@attributes[:channel_ids]).reject(&:blank?).uniq
        unless @organization.alerting_channels.where(id: ids).count == ids.size
          @rule.errors.add(:channel_ids, "must belong to this organization")
          raise ActiveRecord::RecordInvalid, @rule
        end
      end

      # Accetta l'id solo se la risorsa è dell'org corrente; altrimenti nil (project/environment di
      # un'altra org cade in sicurezza). Blank → nil.
      def scoped_id(relation, id)
        relation.where(id: id.presence).pick(:id)
      end
    end
  end
end
