# frozen_string_literal: true

module Member
  # CYRA-1150 — the Undo of a bulk action's toast. Only its author's entry, and only for a few seconds;
  # someone else's id is a 404. Each row goes back only if the actor may still change it, with the same
  # permission the bulk action asked for, and only if nobody changed it since (Undo::Restore).
  class UndosController < Member::BaseController
    permission_not_required "The entry is the actor's own; each row is re-checked with the bulk action's permission.",
                            only: :create

    def create
      entry = ::Undo::Entry.where(account: Current.account, organization: current_organization).find(params[:id])
      return redirect_back_or_to(list_path(entry), alert: t("member.undo.expired")) if entry.expired?

      outcome = ::Undo::Restore.call(entry:, ids: allowed_ids(entry)).value
      refresh_lists(entry, outcome.restored_ids)
      redirect_back_or_to list_path(entry), notice: notice_for(outcome)
    end

    private

    def list_path(entry)
      case entry.kind
      when "error_groups" then member_monitoring_error_groups_path
      when "metric_groups" then member_monitoring_metric_groups_path
      else member_alerting_notifications_path
      end
    end

    def allowed_ids(entry)
      case entry.kind
      when "error_groups" then permitted(visible.error_groups, entry, "errors.triage")
      when "metric_groups" then permitted(visible.metric_groups, entry, "metrics.promote")
      else own_notifications.where(id: entry.item_ids).pluck(:id)
      end
    end

    def permitted(scope, entry, permission)
      scope.where(id: entry.item_ids).includes(:project)
           .select { |group| can?(permission, scope: group.project) }.map(&:id)
    end

    def own_notifications
      ::Alerting::Notification.where(account_id: Current.account.id, organization_id: current_organization.id, via: :in_app)
    end

    # The lists open on the same groups refresh, as after the bulk action itself.
    def refresh_lists(entry, ids)
      return if ids.empty? || entry.kind == "notifications"

      projects = ::Projects::Project.where(id: entry.model.where(id: ids).select(:project_id)).to_a
      broadcast = entry.kind == "error_groups" ? ::Errors::Broadcast : ::Metrics::Broadcast
      broadcast.refresh_list(current_organization, projects:)
    end

    def notice_for(outcome)
      restored = t("member.undo.restored", count: outcome.restored_ids.size)
      return restored if outcome.kept.zero?

      "#{restored} #{t("member.undo.kept", count: outcome.kept)}"
    end
  end
end
