# frozen_string_literal: true

module Secrets
  module Shared
    class Version < ApplicationRecord
      belongs_to :shared_value, class_name: "Secrets::Shared::Value", inverse_of: :versions
      belongs_to :created_by, class_name: "Accounts::Account", optional: true
      attr_readonly :shared_value_id, :number, :value
      encrypts :value
      validates :number, presence: true, uniqueness: { scope: :shared_value_id }
    end
  end
end
