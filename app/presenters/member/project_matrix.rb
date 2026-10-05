# frozen_string_literal: true

module Member
  # CYRA-927/930 — the shape every area landing shares: one table, a row per visible project and a
  # column per signal, plus the all-projects row on top. A subclass names its columns and fills the
  # cells; every column is meant to be ONE query grouped by project, so the cost does not grow with
  # the rows. Cell states: `:count` (a number linking to the filtered list), `:off` (never set up,
  # dashed, leads to setting it up), `:na` (this row cannot have it).
  class ProjectMatrix
    Cell = Data.define(:key, :state, :value, :href, :caption, :alert, :trend, :rising)
    Row = Data.define(:id, :project, :cells)

    # `can` answers a permission key and `visible_paths` lists the area's sidebar entries the viewer
    # sees: a column whose page is hidden from the viewer hides with it.
    def initialize(visible_projects:, account: nil, organization: nil, can: ->(_key) { true }, visible_paths: [])
      @visible_projects = visible_projects
      @account = account
      @organization = organization
      @can = can
      @visible_paths = visible_paths
    end

    # The i18n scope of the area: labels, captions and the table name live under it.
    def i18n_scope = raise(NotImplementedError)

    def columns = raise(NotImplementedError)

    # A hash key => Cell for one project.
    def project_cells(_project) = raise(NotImplementedError)

    # A hash key => Cell for the all-projects row.
    def total_cells = raise(NotImplementedError)

    def projects_scope = @visible_projects.with_attached_icon_image.reorder(:name)

    # F021, F061, F088 — the bar above the table: a name search, "with problems" (a row with a red
    # cell) and a sort on any column. Problems and sort read the same cells the table draws, so the
    # list and the numbers cannot disagree; the default order stays the area's own.
    def listed_scope(query: nil, problems: false, sort: nil)
      scope = projects_scope
      scope = scope.where("projects.name ILIKE ?", "%#{::Projects::Project.sanitize_sql_like(query)}%") if query.present?
      key = sort.to_s.delete_prefix("-").to_sym
      sorting = columns.include?(key)
      return scope unless problems || sorting

      listed = rows(scope.to_a)
      listed = listed.select { |row| row.cells.each_value.any?(&:alert) } if problems
      if sorting
        counted, rest = listed.partition { |row| row.cells.fetch(key).state == :count }
        counted = counted.sort_by.with_index { |row, index| [ row.cells.fetch(key).value, index ] }
        counted.reverse! if sort.to_s.start_with?("-")
        listed = counted + rest
      end
      scope.unscope(:order).in_order_of(:id, listed.map(&:id))
    end

    def rows(projects)
      prepare(projects)
      projects.map { |project| Row.new(id: project.id, project:, cells: project_cells(project).slice(*columns)) }
    end

    def total_row = Row.new(id: "all", project: nil, cells: total_cells.slice(*columns))

    private

    # Hook for a subclass that needs the page's projects before drawing them (one batch query).
    def prepare(_projects) = nil

    def project_ids = @visible_projects.select(:id)

    def count_cell(key, value, href, alert: false, trend: nil, rising: false, caption: nil)
      value = value.to_i
      caption ||= value.positive? ? I18n.t("#{i18n_scope}.#{key}.caption", count: value) : I18n.t("#{i18n_scope}.#{key}.zero")
      Cell.new(key:, state: :count, value:, href:, caption:, alert: alert && value.positive?, trend:, rising:)
    end

    def off_cell(key, href) = Cell.new(key:, state: :off, value: nil, href:, caption: nil, alert: false, trend: nil, rising: false)

    def na_cell(key) = Cell.new(key:, state: :na, value: nil, href: nil, caption: nil, alert: false, trend: nil, rising: false)

    def routes = Rails.application.routes.url_helpers
  end
end
