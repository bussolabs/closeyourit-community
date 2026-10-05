# frozen_string_literal: true

module Ui
  # CYRA-748 — La sezione: superficie flat con l'intestazione titolata, il mattone più ripetuto del
  # prodotto (le pagine ne scrivevano a mano quasi duecento). Non sostituisce `Ui::CardComponent`,
  # che è la superficie con un'intestazione libera: qui l'intestazione È un titolo di secondo
  # livello, ed è quello che rende una pagina leggibile a colpo d'occhio.
  #
  # Il corpo ha il padding standard, ma quando il contenuto arriva al bordo (una tabella, un elenco
  # diviso da righe) si passa `body_class: nil` e il contenuto esce nudo dentro la cornice.
  class SectionComponent < BaseComponent
    renders_one :title
    # La riga che spiega su cosa si basa quello che segue: sta sotto il titolo, dentro la stessa
    # intestazione. Con le azioni accanto, titolo e riga si stringono insieme a sinistra.
    renders_one :subtitle
    renders_one :actions

    # Le quattro misure del titolo di sezione già in uso. Non è una scala libera: il chiamante
    # sceglie fra quelle che il prodotto ha, e una misura nuova è una decisione di design.
    HEADINGS = {
      sm: "font-display text-[13px] font-semibold text-zinc-900 dark:text-zinc-100",
      base: "font-display text-[14px] font-semibold text-zinc-900 dark:text-zinc-100",
      md: "font-display text-[15px] font-semibold text-zinc-900 dark:text-zinc-100",
      lg: "font-display text-[16px] font-semibold text-zinc-900 dark:text-zinc-100"
    }.freeze

    DEFAULT_BODY_CLASS = "px-4 py-4"

    # L'altezza dell'intestazione. `compact` è la fascia più bassa che usano i pannelli affiancati a
    # una tabella: sta in mappa perché aggiungerla come classe del chiamante non basterebbe — due
    # `py-*` nello stesso attributo si contendono la stessa proprietà, e a vincere è quella scritta
    # dopo nel foglio di stile, non quella scritta dopo qui.
    HEADER_PADDINGS = { normal: "px-4 py-3", compact: "px-4 py-2.5", tight: "px-4 py-2",
                        wide: "px-5 py-4" }.freeze

    # Le azioni nell'intestazione la rendono una riga. Le tre grafie sono quelle che le pagine hanno
    # già: `between` è la spaziatura piena, `tight` quella senza respiro fra titolo e comandi,
    # `row` la fila in cui il comando si stacca da sé (`ml-auto` sul figlio).
    HEADER_LAYOUTS = {
      between: "flex items-center justify-between gap-3",
      tight: "flex items-center justify-between",
      row: "flex items-center gap-2"
    }.freeze

    TONES = {
      default: { surface: "border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900", divider: "border-stone-200 dark:border-zinc-800" },
      amber: { surface: "border-amber-200 dark:border-amber-500/40 bg-amber-50/50 dark:bg-amber-500/10", divider: "border-amber-100 dark:border-amber-500/30" }
    }.freeze

    def initialize(title: nil, tone: :default, tag: :div, body_class: DEFAULT_BODY_CLASS,
                   heading_size: :base, header_layout: :between, header_padding: :normal,
                   header_class: nil, test_id: nil, collapsible: false, collapsed: false, **options)
      @plain_title = title
      @tone = tone.to_sym
      raise ArgumentError, "tone sconosciuto: #{tone}" unless TONES.key?(@tone)

      @header_layout = header_layout.to_sym
      raise ArgumentError, "header_layout sconosciuto: #{header_layout}" unless HEADER_LAYOUTS.key?(@header_layout)

      @heading_size = heading_size.to_sym
      raise ArgumentError, "heading_size sconosciuta: #{heading_size}" unless HEADINGS.key?(@heading_size)

      @header_padding = header_padding.to_sym
      raise ArgumentError, "header_padding sconosciuto: #{header_padding}" unless HEADER_PADDINGS.key?(@header_padding)

      # Collapsible: a native <details>, the header is its <summary>. No script, and the browser
      # keeps it reachable from the keyboard.
      @collapsible = collapsible
      @collapsed = collapsed
      @tag = collapsible ? :details : tag
      @body_class = body_class
      @header_class = header_class
      @test_id = test_id
      @options = options
    end

    private

    def header?
      @plain_title.present? || title? || subtitle? || actions?
    end

    def heading
      return unless @plain_title.present? || title?

      content_tag(:h2, title? ? title : @plain_title, class: HEADINGS[@heading_size])
    end

    def html_options
      base = "rounded-lg border #{TONES[@tone][:surface]}"
      return merge_options(base_class: base, test_id: @test_id, options: @options) unless @collapsible

      merge_options(base_class: "group #{base}", test_id: @test_id, options: @options.merge(open: !@collapsed))
    end

    SUMMARY_CLASS = "flex items-center justify-between gap-3 cursor-pointer list-none [&::-webkit-details-marker]:hidden " \
                    "group-open:border-b focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-400"

    # The divider shows only while the section is open: closed, the header is the whole panel.
    def summary_classes
      [ HEADER_PADDINGS[@header_padding], SUMMARY_CLASS, TONES[@tone][:divider], @header_class ].compact.join(" ")
    end

    def header_classes
      [ "#{HEADER_PADDINGS[@header_padding]} border-b #{TONES[@tone][:divider]}",
        (HEADER_LAYOUTS[@header_layout] if actions?), @header_class ]
        .compact.join(" ")
    end
  end
end
