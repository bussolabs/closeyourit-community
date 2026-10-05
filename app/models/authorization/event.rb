# frozen_string_literal: true

module Authorization
  # Audit dei cambi-permesso (mirror di Ticketing::Event): chi (actor; true_actor per impersonation),
  # cosa (action allow-list) e i dettagli (data jsonb con label UMANE snapshottate). I cambi-permesso
  # sono security-sensitive → tracciati. Emesso sync/in-transazione dai service via RecordChange.
  #
  # CYRA-728 — qui finisce anche `dangerous_action_confirmed`: l'uso confermato di una chiave che il
  # catalogo segna pericolosa. È lo stesso registro perché è la stessa domanda — chi ha esercitato un
  # potere che poteva distruggere o allargare — e sdoppiarlo obbligherebbe a leggere in due posti per
  # ricostruire una sola storia.
  class Event < ApplicationRecord
    ACTIONS = %w[
      role_created role_updated role_deleted
      permission_granted permission_revoked
      team_created team_updated team_deleted
      team_member_added team_member_removed
      team_role_added team_role_removed
      team_scope_changed
      account_role_added account_role_removed
      personal_override_set personal_override_cleared
      dangerous_action_confirmed
    ].freeze

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :authorization_events
    belongs_to :actor,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false
    belongs_to :true_actor,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false

    validates :action, presence: true, inclusion: { in: ACTIONS }

    # Tie-break su :id a parità di created_at (ordine totale e deterministico).
    scope :chronological, -> { order(:created_at, :id) }

    def impersonated?
      true_actor_id.present? && true_actor_id != actor_id
    end
  end
end
