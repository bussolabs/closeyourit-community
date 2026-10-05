# frozen_string_literal: true

module Ui
  # Kebab menu azioni di riga: `<details>` nativo (apre/chiude senza JS). Il pannello
  # è posizionato a `position:fixed` dal controller Stimulus `ui--row-menu` (stesso
  # pattern anti-clipping di `ui--tooltip`) → può stare anche dentro una
  # `Ui::TableComponent` scrollabile (`overflow-x-auto`) senza essere clippato. Senza
  # JS il pannello resta `absolute` (fallback ok sulle tabelle non scrollabili).
  #
  # Il contenuto del blocco = le voci. Per le classi-voce usare la class method
  # `Ui::RowMenuComponent.item_class(:default | :danger)`; per il separatore un
  # `<div class="my-1 border-t border-stone-200"></div>`.
  class RowMenuComponent < BaseComponent
    ITEM_BASE = "w-full text-left flex items-center gap-2.5 px-3 h-8 text-[13px]"
    ITEM_VARIANTS = {
      default: "#{ITEM_BASE} text-zinc-900 dark:text-zinc-100 hover:bg-stone-50 dark:hover:bg-zinc-800",
      danger: "#{ITEM_BASE} text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/15"
    }.freeze
    WIDTHS = { md: "w-44", lg: "w-48" }.freeze

    def self.item_class(variant = :default)
      ITEM_VARIANTS.fetch(variant) do
        raise ArgumentError, "Ui::RowMenuComponent: variante voce sconosciuta #{variant.inspect}"
      end
    end

    # The trigger: a square icon, or — with `label:` — icon and text, at the height of a small button.
    TRIGGER_BASE = "list-none cursor-pointer inline-flex items-center justify-center rounded-md text-gray-500 dark:text-zinc-400 hover:bg-stone-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400"
    # h-7/w-7 desktop (denso); max-md:h-11/w-11 = touch target ≥44px su mobile.
    TRIGGER_ICON = "#{TRIGGER_BASE} h-7 w-7 max-md:h-11 max-md:w-11"
    TRIGGER_LABELLED = "#{TRIGGER_BASE} h-7 px-3 gap-[7px] text-[12px] font-medium max-md:h-11"

    def initialize(width: :md, test_id: nil, aria_label: nil, icon: "ellipsis", label: nil, **options)
      @panel_width = WIDTHS.fetch(width) do
        raise ArgumentError, "Ui::RowMenuComponent: width sconosciuta #{width.inspect} (md | lg)"
      end
      @test_id = test_id
      @aria_label = aria_label
      @icon = icon
      @label = label
      @options = options
    end

    private

    def summary_options
      opts = @options.dup
      opts[:data] = (opts[:data] || {}).merge("ui--row-menu-target": "trigger")
      merge_options(
        base_class: @label ? TRIGGER_LABELLED : TRIGGER_ICON,
        test_id: @test_id,
        options: opts
      ).merge("aria-label": @aria_label || I18n.t("shared.actions.row_menu"), "aria-haspopup": "menu")
    end
  end
end
