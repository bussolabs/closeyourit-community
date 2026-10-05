# frozen_string_literal: true

module Secrets
  module Consolidation
    # Accetta una proposta di «valore in comune» (CYRA-777): il valore si sposta UNA volta nei secret
    # dell'organizzazione e i progetti che lo tenevano a mano lo ricevono in delega, ciascuno col nome
    # con cui lo chiama oggi.
    #
    # Tutto in UNA transazione, e non è un dettaglio implementativo: fra il momento in cui la
    # variabile locale sparisce e quello in cui la delega la sostituisce, il progetto non ha quel
    # segreto. Se il giro si interrompesse a metà — una delega rifiutata da una validazione, un
    # progetto con i secret disabilitati su quell'ambiente — resterebbe un'applicazione senza la sua
    # chiave, e nessuno saprebbe che è successo qui. O si sposta tutto, o non si sposta niente.
    #
    # L'invio verso GitHub sta FUORI dalla transazione, come in tutto il dominio: Solid Queue vive su
    # un database separato, quindi un job accodato dentro la transazione partirebbe prima del commit
    # e leggerebbe lo stato di prima.
    class Promote < ApplicationService
      include ::Secrets::Github::Syncable

      StaleConfirmation = Class.new(StandardError) do
        attr_reader :impact

        def initialize(impact)
          @impact = impact
          super("Conferma obsoleta")
        end
      end

      # Non c'è più niente da spostare: il valore non è più ripetuto, oppure il secret
      # dell'organizzazione non si è potuto scrivere (nome già preso, formato sbagliato).
      Refused = Class.new(StandardError) do
        attr_reader :details

        def initialize(message, details = nil)
          @details = details
          super(message)
        end
      end

      # `name:` è il nome del secret dell'organizzazione (default: quello proposto). Ignorato quando
      # l'organizzazione tiene già quel valore: lì si delega il secret che esiste, col nome che ha.
      # `local_names:` è la mappa { project_id => alias }: quello che ogni progetto continuerà a
      # leggere. Assente per un progetto = il nome che quel progetto usa OGGI, che è la scelta giusta
      # nel caso normale — accettare non deve costringere nessuno a toccare il proprio codice.
      def initialize(suggestion:, actor: nil, name: nil, local_names: {}, confirmation_digest: nil)
        @suggestion = suggestion
        @actor = actor
        @name = name.to_s.strip.upcase.presence
        @local_names = (local_names || {}).transform_keys(&:to_s)
        @confirmation_digest = confirmation_digest
      end

      def call
        projects = []
        ApplicationRecord.transaction do
          candidate = verify!
          shared_value = ensure_shared_value(candidate)
          projects = candidate.variables.map(&:project)
          candidate.variables.each { |variable| move(variable, shared_value) }
          @suggestion.update!(status: :promoted, promoted_at: Time.current, promoted_by: @actor,
                              shared_variable: shared_value.shared_variable,
                              projects_count: candidate.projects_count, last_seen_at: Time.current)
        end
        projects.each { |project| enqueue_github_sync(project) }
        Result.ok(@suggestion)
      rescue StaleConfirmation => e
        Result.err(AppError.new(e.message, code: "R409-CONSOLIDATION-001", details: e.impact))
      rescue Refused => e
        Result.err(AppError.new(e.message, code: "R422-CONSOLIDATION-002", details: e.details))
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-CONSOLIDATION-001", details: e.record.errors.as_json))
      end

      private

      # Il mondo dev'essere ancora quello che si è visto, e ci dev'essere ancora qualcosa da spostare.
      def verify!
        impact = Impact.call(suggestion: @suggestion).value
        raise Refused, "Il valore non è più ripetuto in più progetti" if candidate.nil?
        unless ActiveSupport::SecurityUtils.secure_compare(@confirmation_digest.to_s, impact["digest"])
          raise StaleConfirmation, impact
        end
        # CYRA-843: una delega per progetto/valore non può conservare due nomi locali.
        # Rifiutare prima di scrivere o leggere il valore evita una proposta ineseguibile
        # che fallisce soltanto durante la seconda delega.
        if candidate.variables.group_by(&:project_id).any? { |_project_id, variables| variables.size > 1 }
          raise Refused, I18n.t("member.secrets.origins.alias_conflict_body")
        end

        candidate
      end

      def candidate
        return @candidate if defined?(@candidate)

        @candidate = Candidates.call(organization: @suggestion.organization, environment: @suggestion.environment,
                                     fingerprints: [ @suggestion.value_fingerprint ]).value.first
      end

      # Se l'organizzazione tiene GIÀ quel valore, si delega quello: creare un secondo secret identico
      # con un altro nome rifarebbe, dentro l'organizzazione, esattamente il disordine che la proposta
      # esiste per togliere.
      def ensure_shared_value(candidate)
        return candidate.shared_value if candidate.existing_shared?

        result = ::Secrets::Shared::Save.call(
          organization: @suggestion.organization, environment: @suggestion.environment,
          name: @name || @suggestion.suggested_name, value: candidate.variables.first.value,
          actor: @actor, skip_confirmation: true, enqueue_sync: false, action: "created"
        )
        raise Refused.new(result.error.message, result.error.details) if result.err?

        result.value
      end

      # L'ORDINE è il punto: prima sparisce la variabile locale, poi nasce la delega. Al contrario la
      # delega sarebbe rifiutata dalla sua stessa validazione — il progetto avrebbe già un segreto con
      # quel nome, che è proprio quello che si sta per togliere.
      def move(variable, shared_value)
        project = variable.project
        previous_name = variable.name
        # Distruggere un record deve poter toccare le sue dipendenze (`dependent: :destroy` sullo
        # storico dei valori). La variabile arriva da una lista, quindi sotto le prove la guardia
        # letture a raffica (CYRA-747) l'ha marcata: qui la lettura non è una raffica davanti a una
        # pagina, è la cascata di una cancellazione — la stessa eccezione che quella guardia dichiara
        # per i giri che caricano una lista per distruggerla.
        variable.strict_loading!(false)
        variable.destroy!
        ::Secrets::RecordEvent.call(action: "consolidated", project:, environment: @suggestion.environment,
                                    actor: @actor, name: previous_name,
                                    metadata: { shared_name: shared_value.name })
        delegate(project, shared_value, alias_for(project, previous_name, shared_value))
      end

      def delegate(project, shared_value, local_name)
        shared_value.delegations.create!(project:, local_name:)
        ::Secrets::Shared::Event.create!(
          organization: @suggestion.organization, shared_variable: shared_value.shared_variable,
          environment: @suggestion.environment, project:, actor: @actor,
          action: "delegated", name: shared_value.name,
          metadata: { consolidation: true, local_name: local_name }
        )
      end

      # nil quando il nome effettivo coincide col nome del secret dell'organizzazione: un alias uguale
      # al nome non è un alias, e scriverlo lascerebbe una colonna da tenere allineata a mano se un
      # domani il secret dell'organizzazione venisse rinominato.
      def alias_for(project, previous_name, shared_value)
        wanted = (@local_names[project.id.to_s].presence || previous_name).to_s.strip.upcase
        wanted == shared_value.name.to_s.upcase ? nil : wanted
      end
    end
  end
end
