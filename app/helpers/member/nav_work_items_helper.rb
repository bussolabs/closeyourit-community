# frozen_string_literal: true

module Member
  # The WORK section: projects, what we build and fix, product knowledge. Ordered by the real path
  # through the work, not alphabetically (CYRA-742).
  module NavWorkItemsHelper
    private

    def projects_items
      cp = controller.controller_path

      [ { label: "member.nav.projects", path: member_projects_path, icon: "folder",
          test: "member-nav-projects", visible: true, active: cp == "member/projects" } ]
    end

    # What we build and fix: tickets, ideas, workload (CYRA-330). My work is a pinned entry (CYRA-903).
    def product_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_product_path, icon: "compass",
          test: "member-nav-product-overview", visible: true, overview: true, active: overview_active?("product") },
        { label: "member.nav.tickets", path: member_tickets_path, icon: "ticket",
          test: "member-nav-tickets", visible: true,
          active: cp == "member/tickets" && !my_work_active? },
        { label: "member.nav.ideas", path: member_ideas_path, icon: "lightbulb",
          test: "member-nav-ideas", visible: true, active: cp.start_with?("member/ideas") },
        { label: "member.nav.helpdesk", path: member_helpdesk_requests_path, icon: "inbox",
          test: "member-nav-helpdesk", visible: helpdesk_nav_visible?,
          active: cp.start_with?("member/helpdesk_requests") },
        { label: "member.nav.workload", path: member_workload_actions_path, icon: "clipboard-list",
          test: "member-nav-workload", visible: workload_nav_visible?, active: cp.start_with?("member/workload") }
      ]
    end

    # Product knowledge: wiki pages, review, books and the map of what exists on which platform, in
    # the order of the real path (CYRA-415).
    def knowledge_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_knowledge_root_path, icon: "compass",
          test: "member-nav-knowledge-overview", visible: true, overview: true, active: cp == "member/knowledge/overview" },
        { label: "member.nav.knowledge_review", path: member_knowledge_reviews_path, icon: "inbox",
          test: "member-nav-knowledge-review", visible: true, active: cp == "member/knowledge/reviews" },
        { label: "member.nav.knowledge_pages", path: member_knowledge_pages_path, icon: "book-open",
          test: "member-nav-knowledge", visible: true,
          active: cp.in?(%w[member/knowledge/pages member/knowledge/versions]) },
        { label: "member.nav.book", path: member_knowledge_books_path, icon: "book",
          test: "member-nav-book", visible: true, active: cp == "member/knowledge/books" },
        { label: "member.nav.feature_matrix", path: member_product_matrices_path, icon: "layout-grid",
          test: "member-nav-feature-matrix", visible: product_matrix_nav_visible?,
          active: cp.start_with?("member/product") }
      ]
    end
  end
end
