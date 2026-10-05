# frozen_string_literal: true

module Member
  # CYRA-930 — the Infrastructure landing: per project, the sites down out of the ones checked, the
  # scheduled jobs late or missed, the certificates about to expire. Servers belong to the
  # organization, not to a project: they stay in the header counts. The projects with sites down first.
  class InfrastructureMatrix < ProjectMatrix
    COLUMNS = %i[uptime crons certificates].freeze
    CRON_TROUBLE = %i[late missed failing].freeze

    def i18n_scope = "member.overviews.infrastructure"

    def columns = COLUMNS

    def projects_scope
      down = ::Uptime::Monitor.status_down
                              .where(::Uptime::Monitor.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                              .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{down.to_sql}) DESC"), :name)
    end

    def project_cells(project)
      id = project.id
      filter = { project_id: [ id ] }
      {
        uptime: uptime_cell(monitors[id].to_i, down[id].to_i, routes.member_monitoring_monitors_path(filter)),
        crons: crons_cell(crons[id].to_i, crons_trouble[id].to_i, routes.member_monitoring_cron_monitors_path(filter)),
        certificates: if monitors[id].to_i.zero?
                        na_cell(:certificates)
                      else
                        count_cell(:certificates, expiring[id], routes.member_monitoring_monitors_path(filter), alert: true)
                      end
      }
    end

    def total_cells
      {
        uptime: uptime_cell(monitors.values.sum, down.values.sum, routes.member_monitoring_monitors_path),
        crons: crons_cell(crons.values.sum, crons_trouble.values.sum, routes.member_monitoring_cron_monitors_path),
        certificates: count_cell(:certificates, expiring.values.sum, routes.member_monitoring_monitors_path, alert: true)
      }
    end

    private

    def uptime_cell(total, value, href)
      return off_cell(:uptime, routes.member_monitoring_monitors_path) if total.zero?

      count_cell(:uptime, value, href, alert: true, caption: caption(:uptime, value, total))
    end

    def crons_cell(total, value, href)
      return off_cell(:crons, routes.member_monitoring_cron_monitors_path) if total.zero?

      count_cell(:crons, value, href, alert: true, caption: caption(:crons, value, total))
    end

    # "1 down out of 2" reads only with the total next to the number.
    def caption(key, value, total)
      I18n.t("#{i18n_scope}.#{key}.#{value.positive? ? 'caption' : 'zero'}", count: value, total:)
    end

    def monitors = @monitors ||= ::Uptime::Monitor.where(project_id: project_ids).group(:project_id).count

    def down = @down ||= ::Uptime::Monitor.where(project_id: project_ids).status_down.group(:project_id).count

    # Expiring = inside the warning window each monitor sets for itself.
    def expiring
      @expiring ||= ::Uptime::Monitor.where(project_id: project_ids)
                                     .where("ssl_expires_at < NOW() + make_interval(days => ssl_expiry_warn_days)")
                                     .group(:project_id).count
    end

    def crons = @crons ||= ::Crons::Monitor.where(project_id: project_ids).group(:project_id).count

    def crons_trouble
      @crons_trouble ||= ::Crons::Monitor.where(project_id: project_ids, status: CRON_TROUBLE).group(:project_id).count
    end
  end
end
