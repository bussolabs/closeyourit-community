# frozen_string_literal: true

# DESIGN.md A32: the dark look of the rewritten Ui:: components. Dark is opt-in (a `dark` class on
# <html>, today only the Lookbook theme switch), so only these components carry `dark:` classes.
module UiDarkPalette
  COMPONENTS = %w[
    page_header table table_toolbar saved_views pagination kanban card_grid entity_card entity_mark
    details section stat_label confirm_dialog empty_state empty_note no_results icon
    alert assistant audit_meta badge breadcrumb button button_group card changelog changelog_release
    description_list floating_notice github_status histogram input meter metric_tile modal nav_link
    password_rules presence_menu range_filter row_menu select sparkline switch tooltip user_menu voice markdown
  ].freeze

  # Light class => its dark counterpart, zinc ground (page zinc-950, panel zinc-900).
  # Surfaces stay opaque: sticky headers and columns paint over the rows scrolling under them.
  # Colors that read on both grounds (white text, the indigo-600 primary, zinc-900 overlays) stay as they are.
  MAP = {
    "bg-white" => "bg-zinc-900",
    "bg-stone-50" => "bg-zinc-800",
    "bg-stone-100" => "bg-zinc-800",
    "bg-indigo-50" => "bg-indigo-500/15",
    "bg-indigo-100" => "bg-indigo-500/25",
    "bg-rose-50" => "bg-rose-500/15",
    "bg-amber-50/50" => "bg-amber-500/10",
    "bg-stone-100/35" => "bg-zinc-800/35",
    "bg-stone-200" => "bg-zinc-700",
    "bg-stone-300" => "bg-zinc-600",
    "bg-gray-100" => "bg-zinc-800",
    "bg-emerald-50" => "bg-emerald-500/15",
    "bg-emerald-100" => "bg-emerald-500/25",
    "bg-emerald-200" => "bg-emerald-500/35",
    "bg-red-50" => "bg-red-500/15",
    "bg-amber-50" => "bg-amber-500/15",
    "bg-orange-50" => "bg-orange-500/15",
    "bg-teal-50" => "bg-teal-500/15",
    "bg-sky-50" => "bg-sky-500/15",
    "bg-violet-50" => "bg-violet-500/15",
    "text-red-700" => "text-red-300",
    "text-red-500" => "text-red-400",
    "text-amber-700" => "text-amber-300",
    "text-amber-500" => "text-amber-400",
    "text-orange-700" => "text-orange-300",
    "text-emerald-700" => "text-emerald-300",
    "text-green-700" => "text-green-300",
    "text-green-600" => "text-green-400",
    "text-teal-700" => "text-teal-300",
    "text-sky-700" => "text-sky-300",
    "border-indigo-200" => "border-indigo-500/40",
    "border-red-200" => "border-red-500/40",
    "border-emerald-200" => "border-emerald-500/40",
    "border-amber-300" => "border-amber-500/50",
    "ring-indigo-200" => "ring-indigo-500/40",
    "ring-white" => "ring-zinc-900",
    "decoration-indigo-300" => "decoration-indigo-500",
    "bg-stone-50/40" => "bg-zinc-800/40",
    "bg-stone-50/50" => "bg-zinc-800/50",
    "bg-stone-50/60" => "bg-zinc-800/60",
    "bg-stone-50/70" => "bg-zinc-800/70",
    "bg-stone-200/80" => "bg-zinc-700/80",
    "bg-gray-300" => "bg-zinc-600",
    "bg-indigo-50/40" => "bg-indigo-500/10",
    "bg-indigo-50/50" => "bg-indigo-500/10",
    "bg-indigo-50/60" => "bg-indigo-500/15",
    "bg-emerald-50/50" => "bg-emerald-500/10",
    "bg-amber-50/60" => "bg-amber-500/10",
    "bg-amber-100" => "bg-amber-500/25",
    "bg-red-50/40" => "bg-red-500/10",
    "bg-red-50/60" => "bg-red-500/10",
    "bg-red-100" => "bg-red-500/25",
    "text-zinc-800" => "text-zinc-200",
    "text-zinc-600" => "text-zinc-400",
    "text-stone-500" => "text-zinc-400",
    "text-stone-400" => "text-zinc-500",
    "text-slate-500" => "text-zinc-400",
    "text-amber-800" => "text-amber-200",
    "text-amber-900" => "text-amber-200",
    "text-rose-700" => "text-rose-300",
    "text-red-800" => "text-red-200",
    "text-emerald-800" => "text-emerald-200",
    "text-indigo-800" => "text-indigo-200",
    "text-indigo-900" => "text-indigo-200",
    "text-blue-600" => "text-blue-400",
    "border-indigo-100" => "border-indigo-500/20",
    "border-indigo-300" => "border-indigo-500/50",
    "border-red-100" => "border-red-500/20",
    "border-red-300" => "border-red-500/50",
    "border-rose-200" => "border-rose-500/40",
    "border-rose-300" => "border-rose-500/50",
    "border-sky-200" => "border-sky-500/40",
    "ring-indigo-100" => "ring-indigo-500/20",
    "ring-emerald-200" => "ring-emerald-500/40",
    "decoration-indigo-200" => "decoration-indigo-500/60",
    "bg-gray-50" => "bg-zinc-800",
    "bg-slate-100" => "bg-zinc-800",
    "text-slate-700" => "text-zinc-300",
    "text-amber-900/90" => "text-amber-200/90",
    "border-zinc-200" => "border-zinc-800",
    "border-green-200" => "border-green-500/40",
    "border-emerald-100" => "border-emerald-500/20",
    "divide-indigo-100" => "divide-indigo-500/20",
    "divide-amber-100" => "divide-amber-500/20",
    "divide-amber-200" => "divide-amber-500/30",
    "ring-sky-300" => "ring-sky-500/50",
    "text-zinc-900" => "text-zinc-100",
    "text-zinc-700" => "text-zinc-300",
    "text-stone-700" => "text-zinc-300",
    "text-gray-700" => "text-zinc-300",
    "text-gray-600" => "text-zinc-400",
    "text-gray-500" => "text-zinc-400",
    "text-gray-400" => "text-zinc-500",
    "text-gray-300" => "text-zinc-600",
    "text-stone-300" => "text-zinc-600",
    "text-indigo-700" => "text-indigo-300",
    "text-indigo-600" => "text-indigo-400",
    "text-indigo-500" => "text-indigo-400",
    "text-red-600" => "text-red-400",
    "text-rose-600" => "text-rose-400",
    "text-amber-600" => "text-amber-400",
    "text-orange-600" => "text-orange-400",
    "text-violet-600" => "text-violet-400",
    "text-sky-600" => "text-sky-400",
    "text-emerald-600" => "text-emerald-400",
    "text-teal-600" => "text-teal-400",
    "border-stone-100" => "border-zinc-800",
    "border-stone-200" => "border-zinc-800",
    "border-stone-300" => "border-zinc-700",
    "border-stone-400" => "border-zinc-600",
    "border-indigo-600" => "border-indigo-400",
    "border-amber-100" => "border-amber-500/30",
    "border-amber-200" => "border-amber-500/40",
    "divide-stone-100" => "divide-zinc-800",
    "divide-stone-200" => "divide-zinc-800",
    "ring-indigo-500" => "ring-indigo-400",
    "ring-indigo-500/40" => "ring-indigo-400/40",
    "outline-indigo-600" => "outline-indigo-400",
    "decoration-stone-300" => "decoration-zinc-600",
    "decoration-indigo-500" => "decoration-indigo-400"
  }.freeze

  # A mapped light class with its variants (`hover:`, `group-hover/card:`, `aria-[current=true]:`).
  LIGHT_CLASS = /(?<![\w:\/\[\]=&-])((?:[a-z0-9\[\]=\/_&-]+:)*)(#{MAP.keys.sort_by { -it.size }.map { Regexp.escape(it) }.join("|")})(?![\w\/-])/

  # The member and auth pages (A32): their views, their layouts, and the helpers and Stimulus controllers
  # that hand them classes.
  VIEW_GLOBS = %w[
    app/views/member/**/*.erb app/views/shared/**/*.erb app/views/home/**/*.erb
    app/views/valhalla/**/*.erb app/views/layouts/valhalla.html.erb
    app/views/layouts/member.html.erb app/views/layouts/account.html.erb app/views/account/**/*.erb
    app/views/layouts/auth.html.erb app/views/auth/**/*.erb app/helpers/**/*.rb app/javascript/**/*.js
    app/components/*_component.{rb,html.erb} app/constants/ui/**/*.rb
  ].freeze

  def self.files
    components = COMPONENTS.flat_map { |name| Dir[Rails.root.join("app/components/ui/#{name}_component{.*,/**/*.*}")] }
    (components + VIEW_GLOBS.flat_map { Dir[Rails.root.join(it)] }).sort
  end

  def self.dark_class(variants, light)
    "dark:#{variants}#{MAP.fetch(light)}"
  end

  def self.comment?(line)
    line.lstrip.start_with?("#", "<%#", "//")
  end
end
