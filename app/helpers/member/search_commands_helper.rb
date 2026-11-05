# frozen_string_literal: true

module Member
  # How the quick search shows actions on the open ticket and settings found by name (CYRA-1145).
  # Built on Member::SearchHelper#hit, like every other kind of result.
  module SearchCommandsHelper
    ACTION_ICONS = { assign: "user-check", status: "arrow-right-left", automation: "bot" }.freeze

    # The same endpoint as the button on the ticket page, which checks the permission again.
    def search_hit_actions(action)
      href, method, confirm = search_action_target(action)
      hit(href, ACTION_ICONS.fetch(action.kind), action.label, action.ticket.code,
          [ "action", action.kind, (action.value if action.kind == :status) ].compact.join("-"),
          method: method, confirm: confirm,
          blocked: action.blocked && t("member.search.actions.blocked.#{action.blocked}"))
    end

    def search_hit_settings(setting)
      return search_personal_setting(setting) unless setting.project

      href = member_project_settings_path(setting.project, highlight: setting.anchor, anchor: setting.anchor)
      hit(href, setting.icon, setting.label, t("member.search.meta.project_setting", project: setting.project.name),
          "setting-#{setting.project.id}-#{setting.anchor}")
    end

    private

    def search_action_target(action)
      ticket = action.ticket
      case action.kind
      when :assign then [ assignee_member_ticket_path(ticket, assignee_id: action.value), :patch ]
      when :status then [ status_member_ticket_path(ticket, status_id: action.value, inline: 1), :patch ]
      else [ member_ticket_eligibility_path(ticket, eligibility: action.value), :patch,
             t("member.tickets.agent_eligibility.actions.allow_confirm") ]
      end
    end

    def search_personal_setting(setting)
      hit(member_notification_preferences_path, setting.icon, setting.label, t("member.search.meta.personal_setting"),
          "setting-#{setting.anchor}")
    end
  end
end
