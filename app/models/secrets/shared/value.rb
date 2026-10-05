# frozen_string_literal: true

module Secrets
  module Shared
    class Value < ApplicationRecord
      belongs_to :shared_variable, class_name: "Secrets::Shared::Variable", inverse_of: :values
      belongs_to :environment, class_name: "Types::Environment"
      has_many :versions, class_name: "Secrets::Shared::Version", foreign_key: :shared_value_id,
               inverse_of: :shared_value, dependent: :destroy
      has_many :delegations, class_name: "Secrets::Shared::Delegation", foreign_key: :shared_value_id,
               inverse_of: :shared_value, dependent: :destroy
      has_many :projects, through: :delegations

      attr_readonly :shared_variable_id, :environment_id
      encrypts :value
      # Stessa impronta delle variabili di progetto (CYRA-777), per la domanda inversa: se un valore
      # che sta per essere proposto l'organizzazione ce l'ha GIÀ, la proposta è di delegare quello,
      # non di crearne un secondo identico con un altro nome.
      before_save :assign_value_fingerprint
      validates :environment_id, uniqueness: { scope: :shared_variable_id }
      validate :value_not_null
      validate :environment_matches_organization

      delegate :name, :organization, to: :shared_variable

      private

      def assign_value_fingerprint
        self.value_fingerprint = ::Secrets::Consolidation::Fingerprint.for(value)
      end

      def value_not_null
        errors.add(:value, :blank) if value.nil?
      end

      def environment_matches_organization
        return if environment.blank? || shared_variable.blank?
        errors.add(:environment, :invalid) if environment.organization_id != shared_variable.organization_id
      end
    end
  end
end
