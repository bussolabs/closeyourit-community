# frozen_string_literal: true

module Agents
  # A secret the organization lends to its automator machines (CYAU-224, CYAU-228): one per organization,
  # encrypted, write-only from the app. It leaves the model only through `Agents::Hosts::LentCredential`.
  module LentCredential
    extend ActiveSupport::Concern

    included do
      belongs_to :organization, class_name: "Organizations::Organization", inverse_of: model_name.element.to_sym
      belongs_to :set_by, class_name: "Accounts::Account", optional: true

      encrypts :token

      attr_readonly :organization_id

      normalizes :token, with: ->(value) { value.to_s.strip }

      validates :organization_id, uniqueness: true
    end
  end
end
