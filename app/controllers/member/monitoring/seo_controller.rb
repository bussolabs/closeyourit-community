# frozen_string_literal: true

module Member
  module Monitoring
    # Cockpit SEO (CYRA-528). Lettura per chiunque veda i progetti (scoping
    # visible.seo_issues, anti-BOLA); decidere cosa fare di un rilievo — ignora, riapri,
    # promuovi — richiede `seo.triage` sul progetto della riga.
    #
    # `pages` è la seconda scheda della stessa sezione: i rilievi dicono cosa non va, le pagine
    # dicono com'è messo il sito — e servono a capire se un rilievo è un caso isolato o la regola.
    class SeoController < Member::BaseController
      permission_not_required "Rilievi e pagine dei siti visibili: sola lettura, decidere cosa farne è gated più " \
                              "sotto.",
                              only: %i[index show pages]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      SORT_COLUMNS = {
        "severity" => :severity,
        "check" => :check_key,
        "seen" => :last_seen_at
      }.freeze

      PAGE_SORT_COLUMNS = {
        "url" => :path,
        "status" => :status_code,
        "words" => :word_count,
        "seen" => :last_seen_at
      }.freeze

      before_action :set_issue, only: %i[show ignore reopen promote]
      before_action :require_triage, only: %i[ignore reopen promote]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :severity, :status, :area, :project_id, :q, only: :index

      def index
        scope = base_scope.includes(:page, site: %i[project environment])
        scope = scope.where(status: status_filter) if status_filter.any?
        scope = scope.where(severity: severity_filter) if severity_filter.any?
        scope = scope.where(check_key: area_keys) if area_filter.any?
        # Il progetto qui non è una colonna della riga: i rilievi stanno sotto un SITO, e il sito
        # sotto un progetto. Il filtro passa dai siti visibili di quel progetto, non da filter_by_project.
        scope = scope.where(site_id: sites_for_projects) if filter_ids(:project_id).any?
        scope = filter_by_search(scope, "seo_pages.url", joins: :page)

        @issues = paginated(scope.by_severity, columns: SORT_COLUMNS)
        load_filter_projects
        @saved_views = saved_views_for("seo_issues")
        assign_counts
      end

      def show
        @site = @issue.site
        @check = @issue.check
      end

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :project_id, :q, only: :pages

      def pages
        scope = visible.seo_pages.includes(site: :project)
        scope = scope.where(site_id: sites_for_projects) if filter_ids(:project_id).any?
        scope = filter_by_search(scope, "seo_pages.url")

        @pages = paginated(scope.ordered, columns: PAGE_SORT_COLUMNS)
        load_filter_projects
        assign_counts
      end

      # Ci convivo. Non torna aperto da solo alla visita successiva: sarebbe un modo per rimettere
      # in lista una decisione già presa.
      def ignore
        @issue.update!(status: :ignored, triage_note: params[:triage_note].presence)
        redirect_back_to_issue(notice_key: "ignored")
      end

      def reopen
        @issue.update!(status: :open, resolved_at: nil)
        redirect_back_to_issue(notice_key: "reopened")
      end

      def promote
        result = Seo::PromoteToTicket.call(issue: @issue, reporter: Current.account)

        if result.ok?
          redirect_to member_ticket_path(result.value), notice: t("member.monitoring.seo.notices.promoted")
        else
          redirect_to member_monitoring_seo_path(@issue), alert: t("member.monitoring.seo.errors.promote_failed")
        end
      end

      # Visita su richiesta: chi ha appena messo a posto un titolo non deve aspettare il giro
      # notturno per vedere sparire la riga. Un sito per volta — quello che l'utente sta guardando.
      def rescan
        site = visible.seo_sites.find_by(id: params[:site_id])
        if site.nil?
          nothing_to_authorize!
          return redirect_to(member_monitoring_seo_index_path)
        end

        require_permission!("seo.manage", scope: site.project)
        return if performed? # il gate reindirizza invece di sollevare: qui si esce, o la visita partirebbe lo stesso

        Seo::AuditSiteJob.perform_later(site.id)

        redirect_to member_monitoring_seo_sites_path, notice: t("member.monitoring.seo.notices.rescan_started")
      end

      private

      def base_scope = visible.seo_issues

      def set_issue
        @issue = base_scope.includes(:page, site: :project).find_by(id: params[:id])
        # Anti-BOLA: una riga di un progetto che non vedi non esiste, non è "vietata".
        raise ActiveRecord::RecordNotFound if @issue.nil?
      end

      def require_triage = require_permission!("seo.triage", scope: @issue.site.project)

      def status_filter = enum_filter(:status, Seo::Issue.statuses.keys)

      def severity_filter = enum_filter(:severity, Seo::Issue.severities.keys)

      def area_filter = enum_filter(:area, Seo::Check::AREAS)

      def area_keys = area_filter.flat_map { |area| Seo::Check.for_area(area).map(&:key) }

      def sites_for_projects
        visible.seo_sites.where(project_id: filter_ids(:project_id)).select(:id)
      end

      # Le chip dell'header contano SEMPRE su tutto ciò che è visibile, non sulla pagina corrente né
      # sul filtro attivo: servono a dire quanto c'è, non quanto se ne vede adesso.
      def assign_counts
        issues = visible.seo_issues
        @total_count = issues.status_open.count
        @critical_count = issues.status_open.severity_critical.count
        @high_count = issues.status_open.severity_high.count
        @ignored_count = issues.status_ignored.count
        @pages_count = visible.seo_pages.count
        @sites_count = visible.seo_sites.count
      end

      def redirect_back_to_issue(notice_key:)
        redirect_to member_monitoring_seo_path(@issue), notice: t("member.monitoring.seo.notices.#{notice_key}")
      end
    end
  end
end
