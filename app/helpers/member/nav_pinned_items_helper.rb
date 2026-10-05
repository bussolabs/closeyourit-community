# frozen_string_literal: true

module Member
  # The PINNED entries at the top of the sidebar: what gets opened every day, one click away from
  # anywhere and never inside a group. Without an organization only Home is left (CYRA-742).
  module NavPinnedItemsHelper
    # CYRA-903 — how much is waiting behind a pinned entry. The approvals queue is heavy, so its
    # number arrives in a lazy frame after the page; unread conversations and open todos are one
    # indexed count each.
    def nav_item_badge(item)
      case item.id
      when "approvals"
        last = Rails.cache.read(Member::Home::ApprovalCountsController.cache_key(Current.account, current_organization))
        turbo_frame_tag("member-nav-approvals-count", src: member_home_approvals_count_path, loading: :lazy) do
          if last
            render("shared/notification_counter", count: last, label: t("member.nav.approvals_pending", count: last),
                                                  test_id: "member-nav-approvals-badge")
          end
        end
      when "conversations"
        count = chat_unread_count
        render("shared/notification_counter", count: count, label: t("member.nav.chat_unread", count: count),
                                              test_id: "member-nav-conversations-badge")
      when "todos"
        count = todos_open_count
        render("shared/notification_counter", count: count, label: t("member.nav.todos_open", count: count),
                                              test_id: "member-nav-home-todos-badge")
      end
    end

    # Guides: a button in the page footer from md up, a drawer entry on phones. Nil without an organization.
    def guides_nav_item
      return unless current_organization

      build_nav_item(id: "guides", label: "member.nav.guides", path: member_guides_path, icon: "book",
                     test: "member-nav-guides", active: controller.controller_path == "member/guides")
    end

    private

    # CYRA-903 — My work joined the pinned entries (it was two clicks away inside Product) and Guides
    # left them for the sidebar footer: they are opened now and then, not every day.
    def pinned_items
      cp = controller.controller_path

      items = [ { id: "home", label: "member.nav.home", path: root_path, icon: "house",
                 test: "member-nav-home", visible: true, active: cp == "home" } ]

      items += [
        { id: "my_work", label: "member.nav.my_work", path: my_work_path, icon: "user-check",
          test: "member-nav-my-work", visible: true, active: my_work_active? },
        { id: "approvals", label: "member.approvals.title", path: member_home_approvals_path,
          icon: "circle-check", test: "member-nav-approvals", visible: true,
          active: cp == "member/home/approvals" },
        { id: "conversations", label: "member.nav.conversations", path: member_chat_conversations_path,
          icon: "messages-square", test: "member-nav-conversations", visible: true,
          active: cp.start_with?("member/chat") },
        # `member-nav-todos` is the icon shortcut in the top bar: the menu entry keeps its own test-id.
        { id: "todos", label: "member.nav.todos", path: member_todo_lists_path, icon: "list-check",
          test: "member-nav-home-todos", visible: true, active: cp.start_with?("member/todo_lists") }
      ] if current_organization

      items.filter_map { |item| build_nav_item(item) if item[:visible] }
    end

    # The ticket list filtered on the current account (CYRA-163).
    def my_work_path
      list_member_tickets_path(assignee_id: [ Current.account.id ])
    end

    # Lit ONLY when that exact filter is on, so it never steals the highlight from Tickets (CYRA-163).
    def my_work_active?
      controller.controller_path == "member/tickets" && controller.action_name == "list" &&
        params[:assignee_id] == [ Current.account.id.to_s ]
    end
  end
end
