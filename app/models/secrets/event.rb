# frozen_string_literal: true

module Secrets
  # Audit append-only del vault: chi legge/modifica/sincronizza i secret di un progetto. Immutabile
  # (attr_readonly), emesso via Secrets::RecordEvent dai punti di lettura (bundle CLI + endpoint reveal
  # della matrice Member, CYRA-202/CYRA-204 — la lettura web porta `metadata.source: "web"`) e di
  # mutazione (Set/Delete/Import/Sync). `name` è il nome del secret per set/deleted e per il reveal
  # web (per-cella); nil per gli eventi bundle-level (read/imported/synced) che portano il conteggio
  # in `metadata`.
  class Event < ApplicationRecord
    # "denied" (CYRA-78) è l'unica action che NON descrive un accesso avvenuto: è il tentativo fermato
    # dal confine ambienti (403), registrato PRIMA del rifiuto. Senza, un attore ristretto poteva
    # bussare a production quanto voleva senza lasciare traccia da nessuna parte.
    # "override_set"/"override_deleted" (CYRA-79) sono le assegnazioni di un valore PERSONALE: l'actor è
    # l'admin che l'ha deciso, `metadata.target_account_id` la persona che lo riceve — senza quest'ultimo
    # il registro direbbe che qualcosa è cambiato senza dire per chi.
    # "consolidated" (CYRA-777) è la variabile locale tolta dal progetto perché il suo valore si è
    # spostato nei secret dell'organizzazione. NON è "deleted", e la differenza non è di sfumatura: il
    # valore non è sparito, il progetto continua a riceverlo — chiamarla cancellazione manderebbe a
    # tutti l'avviso di un segreto perso che non è mai stato perso.
    ACTIONS = %w[read set deleted imported synced denied override_set override_deleted consolidated].freeze
    # Canale da cui arriva l'evento. nil sugli eventi storici e su quelli emessi dai service di dominio
    # (che servono entrambi i canali): si annota dove il canale è noto, non si indovina.
    CHANNELS = %w[web cli].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project", inverse_of: :secret_events
    belongs_to :environment, class_name: "Types::Environment", optional: true
    belongs_to :actor, class_name: "Accounts::Account", optional: true

    attr_readonly :organization_id, :project_id, :environment_id, :actor_id, :action, :name, :metadata, :channel

    validates :action, inclusion: { in: ACTIONS }
    validates :channel, inclusion: { in: CHANNELS }, allow_nil: true

    scope :recent, -> { order(created_at: :desc) }
  end
end
