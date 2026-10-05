# frozen_string_literal: true

module Accounts
  module Devices
    # Rifiuto browser: marca la concessione denied (no-op se non più pending). La CLI in poll riceverà
    # access_denied.
    class Deny < ApplicationService
      def initialize(grant:)
        @grant = grant
      end

      # La condizione "solo se in attesa" sta DENTRO la UPDATE e non su uno snapshot letto prima
      # (CYRA-806): fra la lettura e la scrittura la concessione può essere stata approvata o
      # consumata, e un rifiuto cieco cancellerebbe quello stato riscrivendolo come negata.
      def call
        denied = Accounts::DeviceGrant.where(id: @grant.id, status: :pending)
                                      .update_all(status: :denied, updated_at: Time.current)
        @grant.reload if denied.positive?
        Result.ok(@grant)
      end
    end
  end
end
