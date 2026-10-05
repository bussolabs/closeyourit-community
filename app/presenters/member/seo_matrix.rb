# frozen_string_literal: true

module Member
  # CYRA-930 — the SEO landing: per project, the sites checked, the findings still open, the critical
  # ones and the pages visited. Only a web project can have a site: the others show a dash, the web
  # ones without a site the way to add the first. The projects with critical findings first.
  class SeoMatrix < ProjectMatrix
    COLUMNS = %i[sites issues critical pages].freeze

    def i18n_scope = "member.overviews.seo"

    def columns = COLUMNS

    def projects_scope
      critical = open_issues.severity_critical
                            .joins(:site).where(::Seo::Site.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                            .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{critical.to_sql}) DESC"), :name)
    end

    def project_cells(project)
      id = project.id
      return { sites: sites_cell(id), issues: na_cell(:issues), critical: na_cell(:critical), pages: na_cell(:pages) } unless sites[id]

      filter = { project_id: [ id ] }
      {
        sites: sites_cell(id),
        issues: count_cell(:issues, issues[id], routes.member_monitoring_seo_index_path(filter)),
        critical: count_cell(:critical, critical[id], routes.member_monitoring_seo_index_path(filter), alert: true),
        pages: count_cell(:pages, pages[id], routes.pages_member_monitoring_seo_index_path(filter))
      }
    end

    # With no site at all nothing was checked: the other three cells are dashes, not clean zeros.
    def total_cells
      total_sites = count_cell(:sites, sites.values.sum, routes.member_monitoring_seo_sites_path)
      return { sites: total_sites, issues: na_cell(:issues), critical: na_cell(:critical), pages: na_cell(:pages) } if sites.empty?

      {
        sites: total_sites,
        issues: count_cell(:issues, issues.values.sum, routes.member_monitoring_seo_index_path),
        critical: count_cell(:critical, critical.values.sum, routes.member_monitoring_seo_index_path, alert: true),
        pages: count_cell(:pages, pages.values.sum, routes.pages_member_monitoring_seo_index_path)
      }
    end

    private

    def sites_cell(id)
      return count_cell(:sites, sites[id], routes.member_monitoring_seo_sites_path(project_id: [ id ])) if sites[id]
      return off_cell(:sites, routes.new_member_monitoring_seo_site_path) if web.include?(id)

      na_cell(:sites)
    end

    def web = @web ||= @visible_projects.analytics_capable.pluck(:id).to_set

    def sites = @sites ||= ::Seo::Site.where(project_id: project_ids).group(:project_id).count

    def open_issues = ::Seo::Issue.status_open

    def by_project(scope) = scope.joins(:site).where(seo_sites: { project_id: project_ids }).group("seo_sites.project_id").count

    def issues = @issues ||= by_project(open_issues)

    def critical = @critical ||= by_project(open_issues.severity_critical)

    def pages = @pages ||= by_project(::Seo::Page)
  end
end
