# frozen_string_literal: true

module Member
  # CYRA-930 — the Alerts landing: per project, the rules written for it, the ones muted right now,
  # and the viewer's own notifications (unread, and received in the last week). Rules written for the
  # whole organization count only in the all-projects row. Neither list filters by project yet, so
  # the cells open the whole list.
  class AlertsMatrix < ProjectMatrix
    RECEIVED_WINDOW = 7.days

    def i18n_scope = "member.overviews.alerts"

    # The rules columns follow the rules page permission, as the menu entry does.
    def columns = @can.call("alerts.manage") ? %i[rules muted unread received] : %i[unread received]

    def projects_scope
      unread = notifications.unread
                            .where(::Alerting::Notification.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                            .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{unread.to_sql}) DESC"), :name)
    end

    def project_cells(project) = cells { |counts| counts[project.id] }

    def total_cells = cells(rules_total: true) { |counts| counts.values.sum }

    private

    def cells(rules_total: false)
      {
        rules: count_cell(:rules, rules_total ? @organization.alerting_rules.enabled.count : yield(rules),
                          routes.member_alerting_rules_path),
        muted: count_cell(:muted, rules_total ? @organization.alerting_rules.muted.count : yield(muted),
                          routes.member_alerting_rules_path, alert: true),
        unread: count_cell(:unread, yield(unread), routes.member_alerting_notifications_path),
        received: count_cell(:received, yield(received), routes.member_alerting_notifications_path)
      }
    end

    def project_rules = ::Alerting::Rule.where(organization_id: @organization.id, project_id: project_ids)

    def rules = @rules ||= project_rules.enabled.group(:project_id).count

    def muted = @muted ||= project_rules.muted.group(:project_id).count

    # The same inbox as the bell in the top bar: the viewer's in-app notifications.
    def notifications
      ::Alerting::Notification.where(account_id: @account.id, organization_id: @organization.id, via: :in_app,
                                     project_id: project_ids)
    end

    def unread = @unread ||= notifications.unread.group(:project_id).count

    def received = @received ||= notifications.where(created_at: RECEIVED_WINDOW.ago..).group(:project_id).count
  end
end
