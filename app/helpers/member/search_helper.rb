# frozen_string_literal: true

module Member
  # How the global search shows each kind of result (CYRA-900). One method per kind keeps the
  # results view free of a fifteen-branch case.
  module SearchHelper
    Hit = Data.define(:href, :icon, :title, :meta, :test_id, :method)

    # Only lists whose index filters by `q` get a "see all" link.
    SEE_ALL_PATHS = {
      projects: :member_projects_path, tickets: :member_tickets_path,
      error_groups: :member_monitoring_error_groups_path, pages: :member_knowledge_pages_path,
      ideas: :member_ideas_path, secrets: :member_vault_variables_path
    }.freeze

    # The side menu flattened: what the viewer can open there, they can find here, and nothing else.
    def search_nav_entries
      tree = member_nav_tree
      entries = tree.pinned.map { |item| search_nav_entry(item) }
      tree.sections.flat_map(&:nodes).each do |node|
        # A group's name is the link to its overview (CYRA-903): the overview is an entry of its own.
        entries << search_nav_entry(node)
        next unless node.respond_to?(:items)

        node.items.each { |item| entries << search_nav_entry(item, node) }
      end
      entries << search_nav_entry(guides_nav_item) if guides_nav_item
      entries.uniq(&:path)
    end

    def search_hit(key, record)
      public_send("search_hit_#{key}", record)
    end

    def search_see_all_path(key, query)
      helper = SEE_ALL_PATHS[key]
      helper && public_send(helper, q: query)
    end

    # Rails' highlight escapes the text and the phrase: the output is safe to render.
    def search_highlight(text, query)
      highlight(text.to_s, query, highlighter: '<mark class="rounded-sm bg-amber-100 dark:bg-amber-500/25 px-0.5 text-inherit">\1</mark>')
    end

    def search_hit_nav(entry)
      hit(entry.path, entry.icon, entry.label, t("member.search.meta.page"), "nav-#{entry.path.parameterize}")
    end

    def search_hit_projects(project)
      hit(member_project_path(project), "folder", project.name, project.key, "project-#{project.id}")
    end

    def search_hit_tickets(ticket)
      hit(member_ticket_path(ticket), "ticket", ticket.title, "#{ticket.code} · #{ticket.project.name}",
          "ticket-#{ticket.id}")
    end

    def search_hit_error_groups(group)
      hit(member_monitoring_error_group_path(group), "bug", group.title, "#{group.project.key} · #{group.culprit}",
          "error-group-#{group.id}")
    end

    def search_hit_pages(page)
      hit(member_knowledge_page_path(page), "book-open", page.title, t("member.search.knowledge_meta"),
          "page-#{page.id}")
    end

    def search_hit_books(book)
      hit(member_knowledge_book_path(book), "book", book.title, t("member.search.meta.book"), "book-#{book.id}")
    end

    def search_hit_ideas(idea)
      hit(member_idea_path(idea), "lightbulb", idea.title, idea.project.key, "idea-#{idea.id}")
    end

    def search_hit_monitors(monitor)
      meta = [ monitor.project.key, monitor.url, (t("member.search.meta.paused") unless monitor.active?) ].compact
      hit(member_monitoring_monitor_path(monitor), "signal", monitor.name, meta.join(" · "), "monitor-#{monitor.id}")
    end

    def search_hit_cron_monitors(cron)
      hit(member_monitoring_cron_monitor_path(cron), "clock", cron.name, "#{cron.project.key} · #{cron.slug}",
          "cron-#{cron.id}")
    end

    def search_hit_servers(host)
      hit(member_monitoring_server_path(host), "server", host.name, host.hostname, "server-#{host.id}")
    end

    def search_hit_groups(group)
      hit(member_group_path(group), "layers", group.name, t("member.search.meta.group"), "group-#{group.id}")
    end

    def search_hit_teams(team)
      hit(member_team_path(team), "users", team.name, t("member.search.meta.team"), "team-#{team.id}")
    end

    # A person has no page of their own: the result opens a direct chat with them.
    def search_hit_people(account)
      hit(member_chat_conversations_path(kind: "direct", account_id: account.id), "user", account.name,
          t("member.search.meta.person"), "person-#{account.id}", method: :post)
    end

    def search_hit_conversations(conversation)
      hit(member_chat_conversation_path(conversation), "messages-square", conversation.title_for(Current.account),
          t("member.search.meta.conversation"), "conversation-#{conversation.id}")
    end

    def search_hit_secrets(secret)
      hit(member_vault_variables_path(q: secret.name), "lock", secret.name,
          t("member.search.meta.secret", count: secret.projects), "secret-#{secret.name}")
    end

    private

    def search_nav_entry(item, group = nil)
      label = group ? "#{item.label} · #{group.label}" : item.label
      ::Search::Global::NavEntry.new(label: label, path: item.path, icon: item.icon || group&.icon || "arrow-right")
    end

    def hit(href, icon, title, meta, test_id, method: nil)
      Hit.new(href: href, icon: icon, title: title, meta: meta, test_id: test_id, method: method)
    end
  end
end
