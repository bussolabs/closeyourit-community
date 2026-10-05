# frozen_string_literal: true

module Ui
  # Pallino/swatch del colore di un progetto (e dot di colonna board): classe `bg-{color}-500`
  # COMPLETA e letterale in un .rb → lo scanner Tailwind v4 la rileva (MAI interpolare `bg-#{color}-500`,
  # verrebbe purgata dal JIT). Vedi `rules/styling.md` + `rules/constants.md`.
  # I badge status/priority usano invece `Ui::BadgeComponent`.
  module Colors
    SWATCH = {
      "indigo" => "bg-indigo-500", "emerald" => "bg-emerald-500", "violet" => "bg-violet-500",
      "amber" => "bg-amber-500", "teal" => "bg-teal-500", "sky" => "bg-sky-500",
      "rose" => "bg-rose-500", "gray" => "bg-gray-400",
      "blue" => "bg-blue-500", "cyan" => "bg-cyan-500", "green" => "bg-green-500",
      "lime" => "bg-lime-500", "orange" => "bg-orange-500", "red" => "bg-red-500",
      "fuchsia" => "bg-fuchsia-500", "pink" => "bg-pink-500"
    }.freeze

    SWATCH_COLORS = SWATCH.keys.freeze
    SWATCH_DEFAULT = "bg-gray-400"

    def self.swatch(color) = SWATCH.fetch(color.to_s, SWATCH_DEFAULT)

    # Chip tint (sfondo tenue + testo) per l'icona di progetto/gruppo dentro `Ui::EntityMarkComponent`.
    # Classi COMPLETE e letterali (stesso vincolo JIT v4 di SWATCH: MAI interpolare).
    CHIP = {
      "indigo" => "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-600 dark:text-indigo-400", "emerald" => "bg-emerald-50 dark:bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
      "violet" => "bg-violet-50 dark:bg-violet-500/15 text-violet-600 dark:text-violet-400", "amber" => "bg-amber-50 dark:bg-amber-500/15 text-amber-600 dark:text-amber-400",
      "teal" => "bg-teal-50 dark:bg-teal-500/15 text-teal-600 dark:text-teal-400", "sky" => "bg-sky-50 dark:bg-sky-500/15 text-sky-600 dark:text-sky-400",
      "rose" => "bg-rose-50 dark:bg-rose-500/15 text-rose-600 dark:text-rose-400", "gray" => "bg-gray-50 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400",
      "blue" => "bg-blue-50 dark:bg-blue-500/15 text-blue-600 dark:text-blue-400", "cyan" => "bg-cyan-50 dark:bg-cyan-500/15 text-cyan-600 dark:text-cyan-400",
      "green" => "bg-green-50 dark:bg-green-500/15 text-green-600 dark:text-green-400", "lime" => "bg-lime-50 dark:bg-lime-500/15 text-lime-600 dark:text-lime-400",
      "orange" => "bg-orange-50 dark:bg-orange-500/15 text-orange-600 dark:text-orange-400", "red" => "bg-red-50 dark:bg-red-500/15 text-red-600 dark:text-red-400",
      "fuchsia" => "bg-fuchsia-50 dark:bg-fuchsia-500/15 text-fuchsia-600 dark:text-fuchsia-400", "pink" => "bg-pink-50 dark:bg-pink-500/15 text-pink-600 dark:text-pink-400"
    }.freeze

    CHIP_DEFAULT = "bg-gray-50 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400"

    def self.chip(color) = CHIP.fetch(color.to_s, CHIP_DEFAULT)
  end
end
