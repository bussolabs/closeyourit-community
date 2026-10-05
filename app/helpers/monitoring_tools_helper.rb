# frozen_string_literal: true

# Helper della card "Monitoring tools" (Projects::ToolsOverview). Mappa lo stato di una fonte al colore
# di Ui::BadgeComponent (dot) e alla label i18n. Colori LITERAL dal set del badge (rules/styling.md).
module MonitoringToolsHelper
  STATUS_COLORS = { ok: :emerald, stale: :amber, missing: :red }.freeze

  def monitoring_tool_status_color(status) = STATUS_COLORS.fetch(status, :gray)

  def monitoring_tool_status_label(status) = t("member.projects.show.tool_status.#{status}")
end
