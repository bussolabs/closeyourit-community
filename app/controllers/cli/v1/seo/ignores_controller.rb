# frozen_string_literal: true

module Cli
  module V1
    module Seo
      # "Ci convivo" come risorsa singleton: PUT ignora, DELETE riapre. Gemello di
      # Vulnerabilities::IgnoresController — il gesto è lo stesso, e riaprire è cancellare l'ignore,
      # non un verbo a sé.
      #
      # Un rilievo ignorato NON torna aperto da solo alla visita successiva: sarebbe un modo per
      # rimettere in lista una decisione già presa.
      class IgnoresController < Cli::V1::BaseController
        before_action :set_issue!
        before_action -> { require_permission!("seo.triage", scope: @issue.site.project) }

        def update
          @issue.update!(status: :ignored, triage_note: params[:triage_note].presence)
          render_ok(SeoIssueSerializer.new(@issue))
        end

        def destroy
          @issue.update!(status: :open, resolved_at: nil)
          render_ok(SeoIssueSerializer.new(@issue))
        end

        private

        # Anti-BOLA: il lookup è dentro i progetti visibili e viene PRIMA del gate, così una riga
        # invisibile dà 404 e non 403.
        def set_issue!
          sites = ::Seo::Site.where(project_id: visible_projects.select(:id))
          @issue = ::Seo::Issue.where(site_id: sites.select(:id))
                               .includes(:page, site: %i[project environment])
                               .find(params[:seo_id])
        end
      end
    end
  end
end
