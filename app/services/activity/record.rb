# frozen_string_literal: true

module Activity
  # Registra un evento del log attività generalizzato. Da chiamare DENTRO la transazione del
  # service di mutazione (audit all-or-nothing) — mirror di Ticketing::RecordActivity. Snapshotta
  # actor_name e deriva l'org dal subject. Ritorna l'Event creato (non un Result).
  class Record < ApplicationService
    def initialize(subject:, action:, data: {}, actor: nil, true_actor: nil)
      @subject = subject
      @action = action
      @data = data
      @actor = actor
      @true_actor = true_actor
    end

    def call
      Activity::Event.create!(
        organization_id: @subject.organization_id,
        subject: @subject,
        actor: @actor,
        true_actor: @true_actor,
        actor_name: @actor&.name,
        action: @action,
        data: @data.deep_stringify_keys
      )
    end
  end
end
