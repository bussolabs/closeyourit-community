# frozen_string_literal: true

module Secrets
  module Shared
    class Event < ApplicationRecord
      # `revealed` (CYRA-202): un value condiviso è stato letto in chiaro dalla matrice (endpoint reveal).
      ACTIONS = %w[created rotated rolled_back delegated unlinked deleted revealed].freeze
      belongs_to :organization, class_name: "Organizations::Organization"
      belongs_to :shared_variable, class_name: "Secrets::Shared::Variable", optional: true
      belongs_to :environment, class_name: "Types::Environment", optional: true
      belongs_to :project, class_name: "Projects::Project", optional: true
      belongs_to :actor, class_name: "Accounts::Account", optional: true
      attr_readonly :organization_id, :shared_variable_id, :environment_id, :project_id, :actor_id,
                    :action, :name, :metadata
      validates :action, inclusion: { in: ACTIONS }
      scope :recent, -> { order(created_at: :desc) }
    end
  end
end
