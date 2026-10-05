# frozen_string_literal: true

module Secrets
  module Shared
    class Variable < ApplicationRecord
      belongs_to :organization, class_name: "Organizations::Organization"
      belongs_to :created_by, class_name: "Accounts::Account", optional: true
      has_many :values, class_name: "Secrets::Shared::Value", foreign_key: :shared_variable_id,
               inverse_of: :shared_variable, dependent: :destroy

      attr_readonly :organization_id
      normalizes :name, with: ->(name) { name.to_s.strip.upcase }
      normalizes :description, with: ->(value) { value.to_s.strip }
      validates :name, presence: true, format: { with: ::Secrets::Variable::NAME_FORMAT },
                       uniqueness: { scope: :organization_id }
      validate :name_not_reserved

      private

      def name_not_reserved
        errors.add(:name, :reserved_prefix) if name.to_s.start_with?(::Secrets::Variable::RESERVED_NAME_PREFIX)
      end
    end
  end
end
