# frozen_string_literal: true

module Member
  # Declarative configuration of the member sidebar. It describes the WHOLE tree, the same on every
  # page: changing page only changes what is lit and which group opens by itself (CYRA-521).
  #
  # RBAC and feature-flag gates live in PermissionGates and Navigation::Visibility and are consumed
  # here. A group without visible leaves is not emitted, and neither is an empty section (CYRA-29).
  #
  # Flat names on purpose: a `Member::Navigation` module would shadow `::Navigation::Group` in every
  # member controller, which calls it by its bare name.
  #
  #   Member::NavTreeHelper         the tree's shape and how it is built
  #   Member::NavPinnedItemsHelper  the pinned entries at the top
  #   Member::NavWorkItemsHelper    Work section: projects, product, knowledge
  #   Member::NavSystemItemsHelper  System section: observability, machines, alerts, agents, SEO
  #   Member::NavAccountItemsHelper Organization section: vault and administration
  module NavigationHelper
    include NavTreeHelper
    include NavPinnedItemsHelper
    include NavWorkItemsHelper
    include NavSystemItemsHelper
    include NavAccountItemsHelper
  end
end
