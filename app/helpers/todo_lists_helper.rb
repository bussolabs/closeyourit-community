# frozen_string_literal: true

# Colours a todo list can take. Literal classes: the Tailwind scanner does not see interpolated ones.
# Any other stored value (the CLI accepts free text) falls back to indigo.
module TodoListsHelper
  TODO_LIST_COLORS = {
    "indigo" => "bg-indigo-500",
    "emerald" => "bg-emerald-500",
    "amber" => "bg-amber-500",
    "red" => "bg-red-500",
    "sky" => "bg-sky-500",
    "violet" => "bg-violet-500"
  }.freeze

  # Items still to do in the account's own lists of the active organization (topbar counter).
  def todos_open_count
    return 0 if Current.account.nil? || current_organization.nil?

    # Memoized: the sidebar and the top bar both show it on every page.
    @todos_open_count ||= Todos::Item.where(done: false)
                                     .where(list_id: Todos::List.for(account: Current.account, organization: current_organization).select(:id))
                                     .count
  end

  def todo_list_color_class(list)
    TODO_LIST_COLORS.fetch(list.color.to_s, TODO_LIST_COLORS["indigo"])
  end

  def todo_list_progress_percent(list)
    return 0 if list.items_count.zero?

    (list.done_count * 100 / list.items_count).round
  end
end
