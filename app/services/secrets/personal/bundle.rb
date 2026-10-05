# frozen_string_literal: true

module Secrets
  module Personal
    # Ritorna la mappa decifrata { name => value } di tutte le variabili personali di [account, organization].
    # È il cuore consumato da `cyi personal run`/download e da `use_cyi_personal` (direnv). La decifratura
    # avviene leggendo `variable.value` (ActiveRecord::Encryption). Niente merge shared (il personale è privato).
    class Bundle < ApplicationService
      def initialize(account:, organization:)
        @account = account
        @organization = organization
      end

      def call
        map = Secrets::Personal::Variable
              .for(account: @account, organization: @organization)
              .ordered
              .each_with_object({}) { |variable, acc| acc[variable.name] = variable.value }

        Result.ok(map.sort.to_h)
      end
    end
  end
end
