# frozen_string_literal: true

module Authorization
  # Crea una riga di audit (Authorization::Event). Va chiamato DENTRO la transazione del service di
  # mutazione: o muta+logga o niente (mirror di Ticketing::RecordActivity). Snapshotta il nome attore.
  # Ritorna l'Event (NON un Result): helper interno ai service, non al controller.
  class RecordChange < ApplicationService
    def initialize(organization:, action:, data: {}, actor: nil, true_actor: nil)
      @organization = organization
      @action = action
      @data = data
      @actor = actor
      @true_actor = true_actor
    end

    def call
      Authorization::Event.create!(
        organization: @organization,
        actor: @actor,
        true_actor: @true_actor,
        actor_name: @actor&.name,
        action: @action,
        data: @data.deep_stringify_keys
      )
    end
  end
end
