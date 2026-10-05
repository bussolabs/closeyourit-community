# frozen_string_literal: true

module Cli
  module V1
    module Vulnerabilities
      # "Convivo col rischio" come risorsa singleton: PUT ignora, DELETE riapre. Gemello di
      # ErrorGroups::MutesController — il gesto è lo stesso, e riaprire è cancellare l'ignore, non un
      # verbo a sé.
      #
      # Una riga ignorata NON torna aperta da sola alla scansione successiva: sarebbe un modo per
      # rimettere in lista una decisione già presa.
      class IgnoresController < Cli::V1::BaseController
        before_action :set_finding!
        before_action -> { require_permission!("vulnerabilities.triage", scope: @finding.project) }

        def update
          @finding.update!(status: :ignored, triage_note: params[:triage_note].presence)
          render_ok(VulnerabilityFindingSerializer.new(@finding))
        end

        def destroy
          @finding.update!(status: :open, resolved_at: nil)
          render_ok(VulnerabilityFindingSerializer.new(@finding))
        end

        private

        # Anti-BOLA: il lookup è dentro i progetti visibili e viene PRIMA del gate, così una riga
        # invisibile dà 404 e non 403.
        def set_finding!
          @finding = ::Vulnerabilities::Finding
                     .where(project_id: visible_projects.select(:id))
                     .includes(:advisory, :project, package: :manifest)
                     .find(params[:vulnerability_id])
        end
      end
    end
  end
end
