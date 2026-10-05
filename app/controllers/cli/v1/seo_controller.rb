# frozen_string_literal: true

module Cli
  module V1
    # Cockpit SEO sul canale CLI (CYRA-528). Cross-progetto come le vulnerabilità e lo stream dei
    # log: su una flotta di siti la domanda vera è "dove sono i problemi gravi", non "cosa ha questo".
    #
    # Scope = rilievi dei progetti VISIBILI (la lettura la governa l'accesso al progetto, nessuna
    # chiave d'azione). Il filtro project_id si risolve dentro visible_projects → fuori scope R404,
    # mai 403: una riga di un progetto che non vedi non esiste, non è "vietata".
    #
    # Il triage — ci convivo, ci ripenso, apri un ticket — vive nei sub-controller singleton (seo/);
    # qui restano la lettura e la visita su richiesta.
    class SeoController < Cli::V1::BaseController
      # La visita muta lo stato del sito (riscrive pagine e rilievi) → gate di configurazione, non di
      # lettura. Il sito si risolve prima, così uno fuori scope dà 404 senza arrivare al permesso.
      before_action :set_rescan_site!, only: :rescan
      before_action -> { require_permission!("seo.manage", scope: @rescan_site.project) }, only: :rescan

      def index
        scope = scoped_issues.includes(:page, site: %i[project environment])
        records, meta = paginate(filtered(scope).by_severity)
        render_ok(SeoIssueSerializer.new(records), meta: meta)
      end

      def show
        issue = visible_issues.includes(:page, site: %i[project environment]).find(params[:id])
        render_ok(SeoIssueSerializer.new(issue))
      end

      # Seconda lista della stessa sezione: i rilievi dicono cosa non va, le pagine dicono com'è
      # messo il sito — e servono a capire se un rilievo è un caso isolato o la regola.
      def pages
        scope = ::Seo::Page.where(site_id: scoped_sites.select(:id)).includes(site: :project)
        scope = scope.where("seo_pages.url ILIKE :q", q: "%#{params[:url]}%") if params[:url].present?
        records, meta = paginate(scope.ordered)
        render_ok(SeoPageSerializer.new(records), meta: meta)
      end

      # Visita su richiesta: chi ha appena messo a posto un titolo non deve aspettare il giro
      # successivo per vedere sparire la riga. Un sito per volta, come nel Member.
      def rescan
        ::Seo::AuditSiteJob.perform_later(@rescan_site.id)
        render_ok({ site_id: @rescan_site.id, audit: "queued" })
      end

      private

      def visible_sites = ::Seo::Site.where(project_id: visible_projects.select(:id))

      def scoped_sites
        return visible_sites if params[:project_id].blank?

        ::Seo::Site.where(project: visible_projects.find(params[:project_id]))
      end

      def visible_issues = ::Seo::Issue.where(site_id: visible_sites.select(:id))

      def scoped_issues
        return visible_issues if params[:project_id].blank?

        ::Seo::Issue.where(site_id: scoped_sites.select(:id))
      end

      # Un valore fuori vocabolario è un filtro che non esiste, non una richiesta malformata: si
      # scarta e si restituisce tutto (stesso comportamento del canale Member).
      def filtered(scope)
        scope = scope.where(status: params[:status]) if ::Seo::Issue.statuses.key?(params[:status])
        scope = scope.where(severity: params[:severity]) if ::Seo::Issue.severities.key?(params[:severity])
        scope = scope.for_area(params[:area]) if ::Seo::Check::AREAS.include?(params[:area])
        scope
      end

      def set_rescan_site! = @rescan_site = visible_sites.find(params[:site_id])
    end
  end
end
