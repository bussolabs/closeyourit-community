# frozen_string_literal: true

module Secrets
  module Consolidation
    # L'avviso che la riga di comando stampa dopo `cyi secrets set` (CYRA-777): «questo valore ce
    # l'hanno già altri N progetti, guarda qui». nil quando non c'è niente da dire.
    #
    # DUE NUMERI E UN INDIRIZZO, mai i nomi dei progetti: chi può scrivere un segreto di un progetto
    # non ha per forza il permesso di sapere quali altri progetti esistono, né cosa ci vive dentro. Il
    # conteggio da solo non dice niente di riservato e basta per decidere se andare a guardare.
    #
    # Non aspetta il giro sulle proposte, che è asincrono: se la proposta esiste già la nomina, se non
    # esiste ancora ricalcola il gruppo al volo e manda alla lista «Da sistemare», dove comparirà. Il
    # contrario — rispondere «nessun valore in comune» perché un job non è ancora partito — sarebbe
    # una risposta sbagliata data con sicurezza.
    class Notice < ApplicationService
      Payload = Data.define(:count, :url) do
        def as_json(*) = { "count" => count, "url" => url }
      end

      def initialize(variable:)
        @variable = variable
      end

      def call
        return Result.ok(nil) if @variable.value_fingerprint.blank?

        suggestion = open_suggestion
        return Result.ok(from_suggestion(suggestion)) if suggestion

        candidate = current_candidate
        return Result.ok(nil) if candidate.nil?

        Result.ok(Payload.new(count: candidate.projects_count, url: routes.member_vault_attention_path))
      end

      private

      def open_suggestion
        Suggestion.where(organization_id: @variable.organization_id,
                         environment_id: @variable.environment_id,
                         value_fingerprint: @variable.value_fingerprint).status_open.first
      end

      def from_suggestion(suggestion)
        Payload.new(count: suggestion.projects_count, url: routes.member_vault_consolidation_path(suggestion))
      end

      def current_candidate
        Candidates.call(organization: @variable.organization, environment: @variable.environment,
                        fingerprints: [ @variable.value_fingerprint ]).value.first
      end

      def routes = Rails.application.routes.url_helpers
    end
  end
end
