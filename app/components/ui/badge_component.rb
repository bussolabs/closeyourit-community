# frozen_string_literal: true

module Ui
  # Badge / chip del design system. Reso come <span>.
  # Pallino colorato opzionale (`dot`) che può "respirare" (`pulse`, motion-safe).
  #
  # Il `color` è una chiave di COLORS (nome colore Tailwind nativo). Le classi sono
  # LETTERALI (non interpolate) perché lo scanner di Tailwind purga `bg-#{color}-50`.
  # `color` è dato utente (status/priority org-custom): un valore fuori palette fa
  # fallback al neutro invece di sollevare — una pagina non deve crashare per un colore.
  # `size`, invece, è una variante di codice: valore ignoto → ArgumentError.
  class BadgeComponent < BaseComponent
    BASE = "inline-flex items-center gap-1 rounded-md font-medium whitespace-nowrap"

    COLORS = {
      gray:    { box: "bg-gray-100 dark:bg-zinc-800 text-gray-700 dark:text-zinc-300",       dot: "bg-gray-400" },
      red:     { box: "bg-red-50 dark:bg-red-500/15 text-red-700 dark:text-red-300",          dot: "bg-red-500" },
      orange:  { box: "bg-orange-50 dark:bg-orange-500/15 text-orange-700 dark:text-orange-300",    dot: "bg-orange-500" },
      amber:   { box: "bg-amber-50 dark:bg-amber-500/15 text-amber-700 dark:text-amber-300",      dot: "bg-amber-500" },
      # CYRA-685 — alias di emerald: il prodotto usa UNA tinta per «positivo».
      green:   { box: "bg-emerald-50 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",   dot: "bg-emerald-500" },
      emerald: { box: "bg-emerald-50 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",   dot: "bg-emerald-500" },
      teal:    { box: "bg-teal-50 dark:bg-teal-500/15 text-teal-700 dark:text-teal-300",        dot: "bg-teal-500" },
      sky:     { box: "bg-sky-50 dark:bg-sky-500/15 text-sky-700 dark:text-sky-300",          dot: "bg-sky-500" },
      indigo:  { box: "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-600 dark:text-indigo-400",    dot: "bg-indigo-500" },
      violet:  { box: "bg-violet-50 dark:bg-violet-500/15 text-violet-600 dark:text-violet-400",    dot: "bg-violet-500" }
    }.freeze

    DEFAULT_COLOR = :gray

    SIZES = {
      sm: "px-1.5 py-0 text-[10px]",
      md: "px-2 py-0.5 text-[11px]"
    }.freeze

    def initialize(label: nil, color: DEFAULT_COLOR, dot: false, pulse: false,
                   icon: nil, size: :md, test_id: nil, **options)
      @label = label
      @color = color.to_sym
      @color = DEFAULT_COLOR unless COLORS.key?(@color)
      @dot = dot || pulse
      @pulse = pulse
      @icon = icon
      @size = size.to_sym
      @test_id = test_id
      @options = options

      raise ArgumentError, "size sconosciuta: #{@size}" unless SIZES.key?(@size)
    end

    private

    def klass
      [ BASE, SIZES.fetch(@size), COLORS.fetch(@color)[:box] ].join(" ")
    end

    def dot_klass
      base = "w-1.5 h-1.5 rounded-full #{COLORS.fetch(@color)[:dot]}"
      @pulse ? "#{base} motion-safe:animate-pulse" : base
    end

    def html_options
      merge_options(base_class: klass, test_id: @test_id, options: @options)
    end
  end
end
