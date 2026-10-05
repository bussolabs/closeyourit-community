# frozen_string_literal: true

module Secrets
  module Health
    # Una riga della pagina "Cosa non torna" (CYRA-409): unisce il descrittore corrente
    # (Secrets::HealthCheck::Anomaly, sempre fresco) al record persistito (Secrets::HealthAnomaly, che
    # porta first_seen_at e l'eventuale acknowledge). Espone `risk_score` per l'ordinamento «prima ciò
    # che conta di più»: la produzione domina, poi un nome che sa di chiave, poi la categoria.
    AnomalyRow = Data.define(:anomaly, :record) do
      # Un ambiente di produzione è quello col code convenzionale "production" (seed Types::InstallDefaults).
      PRODUCTION_CODE = "production"
      # Nomi che indicano un segreto vero (chiave/token/password), non una semplice configurazione.
      SENSITIVE_NAME = /KEY|SECRET|TOKEN|PASSWORD|PWD|CREDENTIAL|PRIVATE|CERT|AUTH/
      # Peso della categoria a parità di ambiente/nome: una delega rotta o un buco pesano più di un
      # ambiente ancora del tutto vuoto (che spesso è solo "non ho ancora iniziato").
      KIND_WEIGHT = { "broken_delegation" => 3, "drift_hole" => 2, "empty_environment" => 1 }.freeze

      def kind = anomaly.kind
      def project = anomaly.project
      def environment = anomaly.environment
      def secret_name = anomaly.secret_name

      def id = record.id
      def first_seen_at = record.first_seen_at
      def acknowledged? = record.status_acknowledged?
      def acknowledgement_reason = record.acknowledgement_reason
      def acknowledged_by = record.acknowledged_by
      def acknowledged_at = record.acknowledged_at

      def production? = environment.code == PRODUCTION_CODE
      def sensitive_name? = secret_name.match?(SENSITIVE_NAME)

      # Più alto = più urgente. Produzione domina su tutto (scenario 3 del ticket), poi il nome sensibile.
      def risk_score
        score = 0
        score += 1000 if production?
        score += 100 if sensitive_name?
        score += KIND_WEIGHT.fetch(kind.to_s, 0)
        score
      end
    end
  end
end
