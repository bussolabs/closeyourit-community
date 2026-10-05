# frozen_string_literal: true

module Cli
  module V1
    # Vault CONDIVISO org-level da terminale (`cyi shared`). A differenza del vault PERSONALE, i dati sono
    # posseduti dall'ORGANIZZAZIONE → gate RBAC `shared_secrets.manage` (org-level, scoped: false), come
    # Member::SharedSecretsController. Una variabile (Secrets::Shared::Variable, univoca per nome nell'org)
    # ha un Secrets::Shared::Value per ciascun environment. I valori NON escono mai da qui (nessun bundle
    # in questo quick-win: solo metadati, come PersonalSecretVariableSerializer).
    class SharedSecretsController < Cli::V1::BaseController
      # Riconosce un UUID nel path param :id; altrimenti :id è trattato come NAME della variabile.
      UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      before_action :require_manage

      # GET .../shared_secrets — metadati (mai i valori).
      def index
        records, meta = paginate(shared_variables.order(:name))
        render_ok(SharedSecretVariableSerializer.new(records), meta:)
      end

      # POST .../shared_secrets — upsert { name, environment (code o uuid), value, description? }.
      # skip_confirmation: true — il flusso di conferma impatto (banner "stai per ruotare un valore
      # delegato a N progetti", Member::SharedSecretsController#create) è UX pensata per un umano che
      # decide interattivamente sul web; il canale CLI è un'azione singola e deliberata (`cyi shared set`),
      # stesso principio di skip_confirmation su Secrets::Personal::Variables::Set.
      def create
        env = resolve_environment! or return

        result = ::Secrets::Shared::Save.call(
          organization: Current.organization, name: params[:name], environment: env,
          value: params[:value], description: params[:description], actor: Current.account,
          skip_confirmation: true
        )

        return render_created(SharedSecretVariableSerializer.new(result.value.shared_variable)) if result.ok?

        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      # DELETE .../shared_secrets/:id — :id = UUID oppure NAME. Elimina l'INTERA variabile (tutti gli
      # ambienti): il web (Member::SharedSecretsController#destroy) non ha un destroy per singolo Value/
      # ambiente, solo per l'intera riga della matrice — replichiamo la stessa semantica (un solo DELETE,
      # effetto totale, nessuna ambiguità riga-vs-cella). Secrets::Shared::Delete richiede sempre
      # confirmation_digests che combacino con l'impatto ricalcolato (il banner "Sei sicuro?" del web);
      # per il canale CLI (azione singola non interattiva) li calcoliamo qui con lo stesso Impact.call
      # usato internamente dal service — nessuna nuova firma su Delete, bypassiamo solo il banner umano,
      # stesso principio di skip_confirmation sulla create.
      def destroy
        variable = find_variable!
        digests = variable.values.map { |value| ::Secrets::Shared::Impact.call(shared_value: value, effect: :delete).value["digest"] }
        result = ::Secrets::Shared::Delete.call(shared_variable: variable, actor: Current.account, confirmation_digests: digests)

        return render_no_content if result.ok?

        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      private

      # UUID → find per id nello scope org; NAME → find_by! per nome (upcase). Not found → RecordNotFound → 404.
      def find_variable!
        ref = params[:id].to_s.strip
        return shared_variables.find(ref) if ref.match?(UUID_FORMAT)

        shared_variables.find_by!(name: ref.upcase)
      end

      def shared_variables
        Current.organization.shared_secret_variables
      end

      def require_manage
        require_permission!("shared_secrets.manage")
      end

      # Risolve l'environment dentro l'ORG (per code o UUID) — a differenza del vault di progetto, qui
      # non c'è un sottoinsieme "dichiarato": qualunque environment dell'organizzazione è un target valido
      # (Secrets::Shared::Value valida solo che l'environment appartenga alla stessa org della variabile).
      # Assente/di un'altra org → 422 (stesso bucket "input non valido" della validazione di Save), non 404:
      # è un parametro del body, non una risorsa di path.
      def resolve_environment!
        ref = params[:environment].to_s.strip
        env = find_environment(ref) if ref.present?
        return env if env

        render_error("R422-SHARED-001", "environment richiesto o inesistente nell'organizzazione",
                     status: :unprocessable_content)
        nil
      end

      def find_environment(ref)
        Current.organization.environments.find_by(id: ref) || Current.organization.environments.find_by(code: ref.downcase)
      end
    end
  end
end
