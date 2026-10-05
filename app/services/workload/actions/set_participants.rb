# frozen_string_literal: true

module Workload
  module Actions
    # Imposta i partecipanti di una action (sostituisce l'insieme, idempotente), SOLO account membri
    # del TEAM della action (anti-BOLA: gli id fuori dal team cadono in silenzio). Transazionale,
    # Result pattern. Pattern Teams::SetTeamMembers.
    class SetParticipants < ApplicationService
      def initialize(action:, account_ids:)
        @action = action
        @account_ids = Array(account_ids).reject(&:blank?)
      end

      def call
        ActiveRecord::Base.transaction do
          keep = Connections::TeamMembership.where(team_id: @action.team_id, account_id: @account_ids).pluck(:account_id)
          current = @action.participations.pluck(:account_id)
          remove = current - keep
          add = keep - current
          @action.participations.where(account_id: remove).destroy_all if remove.any?
          add.each { |account_id| @action.participations.create!(account_id: account_id) }
        end
        Result.ok(@action)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(I18n.t("workload.errors.participants_invalid"),
                                code: "R422-WORKLOAD-002", details: e.record.errors.to_hash))
      end
    end
  end
end
