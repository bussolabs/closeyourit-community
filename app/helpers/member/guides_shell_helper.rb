# frozen_string_literal: true

module Member
  # The guides read like the Administration area: every guide listed on the left, the open one on the
  # right. The catalog of spaces (the guides index) heads the list.
  module GuidesShellHelper
    GuideItem = Data.define(:label, :path, :icon, :test, :active)

    # The guides by what they explain. Every slug has a route member_guides_<slug>_path and a title
    # at member.guides.index.<slug>.title.
    GUIDE_SECTIONS = {
      "start" => %w[overview installation ticket_lifecycle structure assistant],
      "product" => %w[tickets questions helpdesk approvals feature_matrix guidance knowledge knowledge_review],
      "observability" => %w[errors performance logs traces measurements session_health replays uptime crons analytics reports],
      "security" => %w[vulnerabilities seo],
      "infrastructure" => %w[servers],
      "vault" => %w[vault secrets secret_overrides shared_values],
      "organization" => %w[agents skill_bundles datasets permissions activity integrations project_moves]
    }.freeze

    ICONS = {
      "overview" => "compass", "installation" => "plug", "assistant" => "mic", "ticket_lifecycle" => "route", "structure" => "network", "tickets" => "layers",
      "questions" => "circle-question-mark", "helpdesk" => "inbox", "approvals" => "circle-check", "feature_matrix" => "layout-grid",
      "guidance" => "compass", "knowledge" => "book", "knowledge_review" => "inbox", "errors" => "bug",
      "measurements" => "chart-no-axes-combined", "session_health" => "heart-pulse",
      "traces" => "git-branch", "performance" => "gauge", "logs" => "align-left", "replays" => "film", "uptime" => "heart-pulse",
      "crons" => "history", "analytics" => "chart-column", "reports" => "mail-open",
      "vulnerabilities" => "shield-half", "seo" => "file-search", "servers" => "server", "vault" => "vault",
      "secrets" => "key", "secret_overrides" => "user-pen", "shared_values" => "group", "agents" => "bot",
      "skill_bundles" => "boxes", "datasets" => "wand-sparkles", "permissions" => "shield-half",
      "activity" => "history", "integrations" => "plug", "project_moves" => "arrow-left-right"
    }.freeze

    def guides_area?
      %w[member/guides member/guides/installation].include?(controller_path)
    end

    # [[key, heading, items]], the shape the side shell renders.
    def guides_nav
      catalog = GuideItem.new(label: t("member.guides.catalog_title"), path: member_guides_path, icon: "map",
                              test: "member-guides-card-catalog", active: action_name == "index")
      GUIDE_SECTIONS.map do |key, slugs|
        items = slugs.map { |slug| guide_item(slug) }
        items.unshift(catalog) if key == "start"
        [ key, t("member.guides.nav.sections.#{key}"), items ]
      end
    end

    private

    def guide_item(slug)
      GuideItem.new(label: t("member.guides.index.#{slug}.title"), path: public_send("member_guides_#{slug}_path"),
                    icon: ICONS.fetch(slug), test: "member-guides-card-#{slug.dasherize}", active: slug == "installation" ? controller_path == "member/guides/installation" : controller_path == "member/guides" && action_name == slug)
    end
  end
end
