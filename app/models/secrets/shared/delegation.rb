# frozen_string_literal: true

module Secrets
  module Shared
    class Delegation < ApplicationRecord
      belongs_to :shared_value, class_name: "Secrets::Shared::Value", inverse_of: :delegations
      belongs_to :project, class_name: "Projects::Project"

      # Alias del progetto (CYRA-777): il nome con cui QUESTO progetto continua a chiamare il valore.
      # nil = usa il nome del secret dell'organizzazione, che è come si è sempre comportata ogni
      # delega. Serve al consolidamento: il valore è il cardine della proposta, i nomi possono
      # differire da progetto a progetto, e nessuno deve essere costretto a rinominare la propria
      # variabile d'ambiente — e a rimettere le mani nel codice che la legge — per accettare.
      normalizes :local_name, with: ->(value) { value.to_s.strip.upcase.presence }

      validates :project_id, uniqueness: { scope: :shared_value_id }
      validates :local_name, format: { with: ::Secrets::Variable::NAME_FORMAT }, allow_nil: true
      validate :local_name_not_reserved
      validate :valid_target
      validate :effective_name_free

      delegate :environment, to: :shared_value

      # Il nome che il progetto vede davvero in `cyi run` e nei secret di GitHub. TUTTO ciò che
      # risolve un nome per un progetto deve passare di qui: leggere `shared_value.name` direttamente
      # consegnerebbe al progetto un nome diverso da quello che si è visto accettare.
      def effective_name = local_name.presence || shared_value&.name

      # `name` resta il nome del secret dell'organizzazione, com'era prima dell'alias: chi guarda la
      # pagina dell'organizzazione deve leggere il nome di lì, non quello di un progetto.
      def name = shared_value&.name

      private

      def local_name_not_reserved
        return if local_name.blank?

        errors.add(:local_name, :reserved_prefix) if local_name.start_with?(::Secrets::Variable::RESERVED_NAME_PREFIX)
        errors.add(:local_name, :reserved) if ::Secrets::Variable::DERIVED_NAMES.include?(local_name)
        errors.add(:local_name, :reserved_runtime) if ::Secrets::Variable.reserved_runtime_name?(local_name)
      end

      def valid_target
        return if project.blank? || shared_value.blank?
        errors.add(:project, :invalid) if project.organization_id != shared_value.organization.id
        link = project.project_environments.find_by(environment_id: shared_value.environment_id)
        errors.add(:environment, :invalid) unless link
        errors.add(:base, :secrets_disabled) if link && !link.secrets_enabled?
      end

      # Il confine che l'alias sposta: la collisione non si misura più sul nome del secret
      # dell'organizzazione ma sul NOME EFFETTIVO, cioè quello che il progetto riceverà. Due deleghe
      # che atterrano sullo stesso nome nello stesso ambiente si sovrascriverebbero a vicenda nel
      # bundle, e vincerebbe quella letta per ultima: un valore diverso da quello che si legge in
      # pagina, senza nessun errore da nessuna parte. Stessa cosa per una variabile locale omonima.
      #
      # Il vincolo vive qui e non a database perché il nome effettivo è `COALESCE(local_name, nome
      # del secret dell'organizzazione)`: metà del dato sta su un'altra tabella e nessun indice della
      # tabella delle deleghe può vederlo.
      def effective_name_free
        return if project.blank? || shared_value.blank? || effective_name.blank?

        errors.add(:base, :local_secret_conflict) if conflicting_local_secret?
        errors.add(:base, :delegation_conflict) if conflicting_delegation?
      end

      def conflicting_local_secret?
        project.secret_variables.exists?(environment_id: shared_value.environment_id, name: effective_name)
      end

      def conflicting_delegation?
        scope = ::Secrets::Shared::Delegation
          .joins(shared_value: :shared_variable)
          .where(project_id: project_id, secrets_shared_values: { environment_id: shared_value.environment_id })
          .where("COALESCE(secrets_shared_delegations.local_name, secrets_shared_variables.name) = ?", effective_name)
        scope = scope.where.not(id: id) if persisted?
        scope.exists?
      end
    end
  end
end
