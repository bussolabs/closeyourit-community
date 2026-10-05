# frozen_string_literal: true

module Ui
  # Alert / flash DS. Variante validata contro mappa frozen; opzionalmente dismissible
  # (Stimulus controller ui--alert). Il messaggio è il content; `title` è la parte in grassetto.
  class AlertComponent < BaseComponent
    # In the toast stack the dark tint goes solid: a see-through toast shows the page under it.
    VARIANTS = {
      success: { box: "border-emerald-200 dark:border-emerald-500/40 bg-emerald-50 dark:bg-emerald-500/15 dark:in-[#flash-container]:bg-emerald-950", tone: "text-emerald-700 dark:text-emerald-300", icon: "circle-check" },
      warning: { box: "border-amber-200 dark:border-amber-500/40 bg-amber-50 dark:bg-amber-500/15 dark:in-[#flash-container]:bg-amber-950", tone: "text-amber-600 dark:text-amber-400", icon: "triangle-alert" },
      danger: { box: "border-red-200 dark:border-red-500/40 bg-red-50 dark:bg-red-500/15 dark:in-[#flash-container]:bg-red-950", tone: "text-red-600 dark:text-red-400", icon: "circle-alert" },
      info: { box: "border-indigo-200 dark:border-indigo-500/40 bg-indigo-50 dark:bg-indigo-500/15 dark:in-[#flash-container]:bg-indigo-950", tone: "text-indigo-600 dark:text-indigo-400", icon: "info" }
    }.freeze

    def initialize(variant: :info, title: nil, dismissible: false, test_id: nil, **options)
      @variant = variant.to_sym
      @title = title
      @dismissible = dismissible
      @test_id = test_id
      @options = options

      raise ArgumentError, "variante sconosciuta: #{@variant}" unless VARIANTS.key?(@variant)
    end

    private

    def spec
      VARIANTS.fetch(@variant)
    end

    def html_options
      base = "flex items-start gap-3 rounded-md border px-4 py-3 #{spec[:box]}"
      opts = merge_options(base_class: base, test_id: @test_id, options: @options)
      opts[:data] = (opts[:data] || {}).merge(controller: "ui--alert") if @dismissible

      # danger/warning interrompono lo screen reader (assertive); success/info sono annunciate
      # educatamente a fine lettura (polite) — vedi WAI-ARIA alert vs status.
      live = if %i[danger warning].include?(@variant)
        { role: "alert", "aria-live": "assertive" }
      else
        { role: "status", "aria-live": "polite" }
      end
      opts.merge!(live)
      opts
    end
  end
end
