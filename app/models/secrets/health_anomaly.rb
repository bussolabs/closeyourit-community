# frozen_string_literal: true

module Secrets
  # Memoria persistita di una singola anomalia del Vault (CYRA-409). Secrets::HealthCheck resta la
  # fonte di verità di "cosa è anomalo ADESSO" (ricalcolo al volo, sempre fresco); questo record dà i
  # due dati che il calcolo non può avere da solo:
  #   - `first_seen_at`: da quando l'anomalia è osservata (mostrato su ogni riga);
  #   - l'acknowledge: la decisione «questa assenza è voluta», che vale per il progetto/organizzazione
  #     (non per la persona) e resta scritta con CHI l'ha presa e QUANDO (risposta del cliente su CYRA-409).
  #
  # Vocabolario di stato identico a Vulnerabilities::Finding, perché il gesto è lo stesso: `resolved` la
  # mette la scansione quando l'anomalia sparisce, `acknowledged` la mette una persona. Un'anomalia
  # acknowledged NON torna `open` da sola alla scansione successiva: rimetterla in lista ignorerebbe la
  # decisione già presa. Il mantenimento (open/resolve/riapertura) vive in Secrets::Health::RecordAnomalies,
  # mai in un callback qui.
  class HealthAnomaly < ApplicationRecord
    self.table_name = "secrets_health_anomalies"

    # Le stesse 3 categorie di Secrets::HealthCheck.
    enum :kind, { drift_hole: 0, empty_environment: 1, broken_delegation: 2 }, prefix: :kind
    enum :status, { open: 0, resolved: 1, acknowledged: 2 }, prefix: :status

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :environment, class_name: "Types::Environment"
    # Chi ha marcato l'assenza come voluta (nullify: l'anomalia sopravvive alla cancellazione dell'account).
    belongs_to :acknowledged_by, class_name: "Accounts::Account", optional: true

    validates :first_seen_at, presence: true
    validates :last_seen_at, presence: true
    # Unicità dell'identità [progetto, ambiente, categoria, nome]: garantita dall'unique index DB
    # (index_secrets_health_anomalies_on_identity). NON una validazione applicativa perché l'unico
    # writer, Secrets::Health::RecordAnomalies, scrive in blocco (insert_all/update_all) dentro la
    # request e una SELECT di uniqueness per record sarebbe un N+1 sotto il guard Prosopite.

    scope :active, -> { where(status: %i[open acknowledged]) }

    # Le anomalie ancora vere ADESSO, scoped ai progetti passati (quelli visibili all'utente).
    scope :for_projects, ->(project_ids) { where(project_id: project_ids) }
  end
end
