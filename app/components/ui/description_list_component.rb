# frozen_string_literal: true

module Ui
  # CYRA-748 — L'elenco descrittivo: le coppie etichetta/valore dei riquadri «Dettagli». Le pagine
  # scrivevano a mano quasi cento volte la stessa etichetta monospazio maiuscoletta e il valore
  # sotto, e ogni riquadro finiva per avere una spaziatura sua.
  #
  # Il valore semplice passa da `value:`; quando è composto (un link, una pastiglia, una riga di
  # icone) si passa il blocco e l'autore scrive il proprio contenuto — la grafia dell'etichetta
  # resta comunque una sola.
  class DescriptionListComponent < BaseComponent
    LABEL = "font-mono uppercase text-[9.5px] tracking-[1.2px] text-gray-500 dark:text-zinc-400"
    # L'aiuto accanto all'etichetta la rende una riga.
    LABEL_WITH_HINT = "#{LABEL} flex items-center gap-1"
    DEFAULT_VALUE_CLASS = "mt-1 font-mono text-[12px] text-zinc-900 dark:text-zinc-100"

    SPANS = {
      1 => "col-span-1", 2 => "col-span-2", 3 => "col-span-3", 4 => "col-span-4",
      full: "col-span-full"
    }.freeze

    # La voce vive in un file suo (`description_list_component/item.rb`) e si nomina qui per stringa:
    # citarla per costante la farebbe caricare mentre questa classe si sta ancora definendo.
    renders_many :items, "Ui::DescriptionListComponent::Item"

    def initialize(columns: 2, gap_y: 3, gap_x: 4, test_id: nil, **options)
      @columns = columns
      @gap_y = gap_y
      @gap_x = gap_x
      @test_id = test_id
      @options = options
      raise ArgumentError, "columns fuori mappa: #{columns}" unless GridComponent::COLS.key?(columns)
    end

    private

    def grid
      GridComponent.new(cols: @columns, gap_y: @gap_y, gap_x: @gap_x, test_id: @test_id, **@options)
    end
  end
end
