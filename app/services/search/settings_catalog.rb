# frozen_string_literal: true

module Search
  # The settings the quick search finds by name (CYRA-1145): the sections of a project's Settings page,
  # with the permissions of member/project_settings/_nav, and the personal notification preferences.
  class SettingsCatalog
    Setting = Data.define(:anchor, :label, :icon, :project)

    # anchor => [label key, icon, permissions all required]
    PROJECT_SECTIONS = {
      "tokens" => [ "member.tokens.section_title", "key", %w[tokens.manage] ],
      "ingest" => [ "member.project_settings.ingest_section", "globe", %w[projects.edit] ],
      "tickets" => [ "member.project_settings.tickets_section", "ticket", %w[projects.edit] ],
      "retention" => [ "member.project_settings.retention_section", "history", %w[projects.edit] ],
      "thresholds" => [ "member.project_settings.thresholds_section", "timer", %w[projects.edit] ],
      "production" => [ "member.project_settings.production_hold_section", "hourglass", %w[projects.edit] ],
      "features" => [ "member.project_settings.features_section", "toggle-right", %w[projects.edit] ],
      "supporter" => [ "member.project_settings.supporter_section", "life-buoy", %w[projects.edit] ],
      "council" => [ "member.project_settings.council_section", "users", %w[projects.edit] ],
      "automator-live" => [ "member.project_settings.automator_live_section", "code", %w[projects.edit] ],
      "dashboard" => [ "member.dashboards.settings.title", "gauge", %w[projects.edit] ],
      "danger" => [ "member.projects.show.danger_title", "triangle-alert", %w[projects.edit projects.delete] ]
    }.freeze

    # Personal settings: everyone manages their own, no permission.
    PERSONAL = { "notifications" => [ "member.nav.bottom_notifications", "bell" ] }.freeze

    def initialize(projects:, can:)
      @projects = projects
      @can = can
    end

    def matching(query)
      words = query.downcase.split
      found = ->(label) { words.all? { |word| label.downcase.include?(word) } }
      personal = PERSONAL.filter_map do |anchor, (key, icon)|
        Setting.new(anchor:, label: I18n.t(key), icon:, project: nil) if found.call(I18n.t(key))
      end
      personal + project_settings(found)
    end

    private

    # Labels are filtered first: permissions are asked only for the sections that matched.
    def project_settings(found)
      sections = PROJECT_SECTIONS.select { |_anchor, (key, _icon, _keys)| found.call(I18n.t(key)) }
      return [] if sections.empty?

      @projects.flat_map do |project|
        sections.filter_map do |anchor, (key, icon, keys)|
          next unless keys.all? { |permission| @can.call(permission, scope: project) }

          Setting.new(anchor:, label: I18n.t(key), icon:, project:)
        end
      end
    end
  end
end
