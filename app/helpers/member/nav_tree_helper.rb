# frozen_string_literal: true

module Member
  # The SHAPE of the sidebar tree and how it is built: node types, sections, the "no orphan header"
  # rule and each group's overview. The entries themselves are declared by the other parts (CYRA-742).
  module NavTreeHelper
    # One destination: a pinned entry, a simple top-level entry or a leaf inside a group. `id` is set
    # only on top-level nodes.
    NavItem = Data.define(:id, :label, :path, :icon, :test, :active, :overview)

    # A group that opens and closes. Its name links to the overview (`path`, `link_test`) and `items`
    # are the leaves without it (CYRA-903). `active` = holds the open page, overview included.
    NavGroup = Data.define(:id, :label, :icon, :test, :path, :link_test, :overview_active, :items, :active) do
      def active? = active
    end

    # A section label: not clickable, leads nowhere.
    NavSection = Data.define(:id, :label, :test, :nodes)

    NavTree = Data.define(:pinned, :sections)

    # Explicit map, not a convention: Projects has no overview (it is its own destination) and
    # knowledge keeps its older landing page (CYRA-415).
    GROUP_OVERVIEWS = {
      "product" => :member_product_path,
      "knowledge" => :member_knowledge_root_path,
      "observability" => :member_observability_path,
      "infrastructure" => :member_infrastructure_path,
      "alerts" => :member_alerts_path,
      "automation" => :member_automation_path,
      "seo" => :member_seo_path,
      "vault" => :member_vault_path
      # CYRA-911 — Administration has no landing: its pages list the sections on the left.
    }.freeze

    def member_nav_tree
      NavTree.new(pinned: pinned_items, sections: nav_sections)
    end

    # The breadcrumb needs it to link back to the area level; nil when the group has no overview.
    def group_overview_path(group)
      helper = GROUP_OVERVIEWS[group.id]
      helper && public_send(helper)
    end

    # A group's visible leaves, overview excluded: counting it would make an empty group look full.
    def group_leaf_items(group)
      definitions = node_definitions[group.id] || []
      definitions.filter_map { |item| build_nav_item(item) if item[:visible] && !item[:overview] }
    end

    private

    def nav_sections
      return [] unless current_organization

      Navigation::Group::SECTIONS.filter_map do |section|
        nodes = section_nodes(section)
        next if nodes.empty?

        NavSection.new(id: section, label: t("member.nav.section_#{section}"),
                       test: "member-nav-section-#{section}", nodes: nodes)
      end
    end

    def section_nodes(section)
      Navigation::Group.sections.fetch(section).filter_map do |group|
        if group.subnav? then build_subnav_node(group)
        elsif group.children? then build_nav_group(group)
        else build_simple_node(group)
        end
      end
    end

    # A group left with its overview only is not emitted: an entrance to a room you cannot enter
    # (CYRA-29).
    def build_nav_group(group)
      leaves = group_leaf_items(group)
      return if leaves.empty?

      overview = node_definitions.fetch(group.id).find { |item| item[:overview] }
      overview_active = overview.present? && overview[:active]

      NavGroup.new(id: group.id, label: group.label, icon: group.icon, test: "member-nav-group-#{group.id}",
                   path: group_overview_path(group), link_test: overview&.dig(:test),
                   overview_active: overview_active, items: leaves,
                   active: overview_active || leaves.any?(&:active))
    end

    # CYRA-911 — one entry for an area whose pages carry their own section list: it opens the first
    # section the account can see and stays lit on every page of the area. Hidden when none is visible.
    def build_subnav_node(group)
      first = group_leaf_items(group).first
      return unless first

      NavItem.new(id: group.id, label: group.label, path: first.path, icon: group.icon,
                  test: "member-nav-#{group.id}", active: admin_area?, overview: false)
    end

    def build_simple_node(group)
      definition = node_definitions.fetch(group.id).first
      build_nav_item(definition.merge(id: group.id)) if definition[:visible]
    end

    def build_nav_item(item)
      NavItem.new(id: item[:id], label: t(item[:label]), path: item[:path], icon: item[:icon],
                  test: item[:test], active: item[:active], overview: item.fetch(:overview, false))
    end

    # Every overview comes from the same controller: the route's group_id tells them apart.
    def overview_active?(group_id)
      controller.controller_path == "member/overviews" && params[:group_id] == group_id
    end

    # The leaves of every top-level node; a simple entry (projects) declares one, its destination.
    # Memoized: each render walks it several times.
    def node_definitions
      @node_definitions ||= {
        "projects" => projects_items,
        "product" => product_items,
        "knowledge" => knowledge_items,
        "observability" => observability_items,
        "infrastructure" => infrastructure_items,
        "alerts" => alerts_items,
        "automation" => automation_items,
        "seo" => seo_items,
        "vault" => vault_items,
        "settings" => settings_items
      }
    end
  end
end
