# frozen_string_literal: true

module Cli
  module V1
    # Vault PERSONALE per-utente da terminale (`cyi personal`). Dati POSSEDUTI dall'account → nessuna
    # permission key: lo scope è l'ownership (Secrets::Personal::Variable.for(account, org)), il find dentro
    # quello scope è anti-BOLA (secret altrui → RecordNotFound → R404). Struttura FLAT (niente environment).
    # I valori escono SOLO da `bundle` (mai dalle liste); ogni bundle registra un evento audit `read`.
    class PersonalSecretsController < Cli::V1::BaseController
      # Riconosce un UUID nel path param :id; altrimenti :id è trattato come NAME del secret.
      UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      # GET .../personal_secrets — metadati (mai i valori).
      def index
        records, meta = paginate(owned_secrets.ordered)
        render_ok(PersonalSecretVariableSerializer.new(records), meta:)
      end

      # GET .../personal_secrets/bundle — mappa decifrata { NAME => value }.
      def bundle
        result = ::Secrets::Personal::Bundle.call(account: Current.account, organization: Current.organization)
        # Audit: la lettura programmatica dei VALORI (cyi personal bundle/run) è tracciata.
        ::Secrets::Personal::RecordEvent.call(action: "read", account: Current.account,
                                              organization: Current.organization,
                                              metadata: { count: result.value.size })
        render_ok(result.value)
      end

      # POST .../personal_secrets — upsert { name, value, description? }.
      def create
        result = ::Secrets::Personal::Variables::Set.call(
          account: Current.account, organization: Current.organization,
          name: params[:name], value: params[:value], description: params[:description]
        )

        return render_created(PersonalSecretVariableSerializer.new(result.value)) if result.ok?

        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      # POST .../personal_secrets/import — import bulk all-or-nothing { variables: [{name,value,description}] }.
      def import
        entries = Array(params[:variables]).map do |v|
          { name: v[:name], value: v[:value], description: v[:description] }
        end
        result = ::Secrets::Personal::Variables::Import.call(
          account: Current.account, organization: Current.organization, entries:
        )

        if result.err?
          return render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
        end

        render json: { data: { imported: result.value.size } }, status: :created
      end

      # DELETE .../personal_secrets/:id — :id = UUID oppure NAME. Not found → RecordNotFound → 404.
      def destroy
        variable = find_variable!
        result = ::Secrets::Personal::Variables::Delete.call(variable:)

        return render_no_content if result.ok?

        render_error(result.error.code, result.error.message, status: result.error.status)
      end

      private

      def owned_secrets
        ::Secrets::Personal::Variable.for(account: Current.account, organization: Current.organization)
      end

      # UUID → find per id nello scope; NAME → find_by! per nome (upcase). Not found → RecordNotFound → 404.
      def find_variable!
        ref = params[:id].to_s.strip
        return owned_secrets.find(ref) if ref.match?(UUID_FORMAT)

        owned_secrets.find_by!(name: ref.upcase)
      end
    end
  end
end
