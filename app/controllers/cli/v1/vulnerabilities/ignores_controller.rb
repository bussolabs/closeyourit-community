# frozen_string_literal: true

module Cli
  module V1
    module Vulnerabilities
      # "Convivo col rischio" come risorsa singleton: PUT ignora, DELETE riapre. Gemello di
      # ErrorGroups::MutesController — il gesto è lo stesso, e riaprire è cancellare l'ignore, non un
      # verbo a sé.
      #
      # CYRA-1144 — ignorare è una decisione a tempo: `reason` e `ignored_until` (data ISO 8601, futura)
      # sono obbligatori, con la stessa regola della pagina (Vulnerabilities::IgnoreFinding). La
      # scansione non riapre una riga ignorata; la riapre il controllo giornaliero alla scadenza.
      class IgnoresController < Cli::V1::BaseController
        # Richiesta di un comando che non conosce motivo e scadenza (la vecchia `--note` facoltativa).
        OUTDATED_CLIENT_CODE = "R422-VULNERABILITY-002"

        before_action :set_finding!
        before_action -> { require_permission!("vulnerabilities.triage", scope: @finding.project) }

        def update
          result = ::Vulnerabilities::IgnoreFinding.call(
            finding: @finding, reason: params[:reason], ignored_until: params[:ignored_until],
            actor: Current.account
          )
          return render_ok(VulnerabilityFindingSerializer.new(result.value)) if result.ok?

          render_ignore_error(result.error)
        end

        def destroy
          @finding.reopen!
          render_ok(VulnerabilityFindingSerializer.new(@finding))
        end

        private

        # Anti-BOLA: il lookup è dentro i progetti visibili e viene PRIMA del gate, così una riga
        # invisibile dà 404 e non 403.
        def set_finding!
          @finding = ::Vulnerabilities::Finding
                     .where(project_id: visible_projects.select(:id))
                     .includes(:advisory, :project, :ignored_by, package: :manifest)
                     .find(params[:vulnerability_id])
        end

        # Il rifiuto è lo stesso per tutti; cambia solo come lo si spiega. Un comando che non manda
        # nessuno dei due campi è una versione vecchia: dirgli «manca il motivo» lo lascerebbe a
        # cercare un'opzione che non ha, mentre la mossa giusta è aggiornarlo.
        def render_ignore_error(error)
          if params.key?(:reason) || params.key?(:ignored_until)
            return render_error(error.code, error.message, status: error.status, details: error.details)
          end

          render_error(OUTDATED_CLIENT_CODE,
                       "Ignoring a vulnerability now needs a reason and an expiry date: update the CLI " \
                       "and run the command again with --reason and --until",
                       status: :unprocessable_content, details: error.details)
        end
      end
    end
  end
end
