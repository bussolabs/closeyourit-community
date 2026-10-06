# frozen_string_literal: true

module Agents
  # Who works and who reviews for the whole organization (CYAU-227). A machine with no choice of its own
  # follows it; `Agents::Host#effective_work_engine` and `#effective_reviewer` resolve the choice in force.
  class AutomatorSetting < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :automator_setting

    validates :work_engine, inclusion: { in: Host::WORK_ENGINES }
    validates :reviewer, inclusion: { in: Host::REVIEWERS }
    validates :organization_id, uniqueness: true
    # CYAU-228 — the OpenRouter model OpenCode reviews with, as OpenRouter names it ("vendor/model").
    normalizes :opencode_model, with: ->(value) { value.to_s.strip.presence }
    validates :opencode_model, format: { with: %r{\A[a-z0-9][a-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:-]*\z} }, allow_nil: true
    validates :opencode_model, presence: true, if: :reviews_with_opencode?

    # An organization that never chose gets the column defaults: Claude works, Codex reviews.
    def self.for(organization) = organization.automator_setting || new

    private

    # The organization's own choice, or a machine that chose OpenCode for itself: both review with this model.
    def reviews_with_opencode?
      reviewer == "opencode" || (organization.present? && organization.agent_hosts.exists?(reviewer: "opencode"))
    end
  end
end
