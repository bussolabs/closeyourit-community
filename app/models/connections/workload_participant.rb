# frozen_string_literal: true

module Connections
  # Join Workload::Action ↔ Accounts::Account: i membri del team assegnati a una action (N per action).
  # Il partecipante deve essere membro del TEAM della action (più stretto dell'org): i partecipanti
  # vengono dal team che possiede la board. Speculare a Connections::TeamMembership.
  class WorkloadParticipant < ApplicationRecord
    belongs_to :action,
               class_name: "Workload::Action",
               inverse_of: :participations
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :workload_participations

    validates :account_id, uniqueness: { scope: :action_id }
    validate :account_belongs_to_action_team

    private

    def account_belongs_to_action_team
      return if account.blank? || action.blank?

      member = Connections::TeamMembership.exists?(account_id: account_id, team_id: action.team_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
