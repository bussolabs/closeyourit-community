# frozen_string_literal: true

require "rails_helper"

# CYRA-568 — «2,841» in una pagina italiana si legge come due virgola otto, e «Scadenza and
# Assegnatario» è mezza frase in inglese. Il progetto non monta rails-i18n e la locale italiana
# definiva a mano solo date e ore: numeri ed elenchi cadevano sui default inglesi di Rails.
# Questa spec è la guardia: se le chiavi spariscono, il difetto torna in tutto il prodotto.
RSpec.describe "Numeri ed elenchi in italiano", type: :helper do
  include ActionView::Helpers::NumberHelper

  describe "migliaia e decimali" do
    it "separa le migliaia col punto" do
      expect(number_with_delimiter(2841, locale: :it)).to eq("2.841")
      expect(number_with_delimiter(54_518, locale: :it)).to eq("54.518")
    end

    it "scrive i decimali con la virgola" do
      expect(number_with_delimiter(1234.5, locale: :it)).to eq("1.234,5")
    end

    it "le percentuali usano la virgola per i decimali" do
      expect(number_to_percentage(99.9, precision: 1, locale: :it)).to eq("99,9%")
    end

    # CYRA-568 — `number.format` si fonde DENTRO i namespace derivati (`human`, `currency`), che
    # hanno regole proprie: dichiarare solo il primo porta la precisione dei conteggi sui byte e
    # scrive «1,500 KB» dove si leggeva «1,5 KB». I derivati vanno ridichiarati.
    it "le dimensioni dei file restano corte e in italiano" do
      expect(number_to_human_size(1536, locale: :it)).to eq("1,5 KB")
      expect(number_to_human_size(512, locale: :it)).to eq("512 Byte")
    end

    it "i decimali dei soldi restano due" do
      expect(number_to_currency(12_345.6, locale: :it)).to match(/12\.345,60(?!\d)/)
    end

    # Le chiavi italiane non devono arrivare all'inglese attraverso i fallback (`fallbacks = [:it]`).
    it "l'inglese resta col formato inglese" do
      expect(number_with_delimiter(2841, locale: :en)).to eq("2,841")
      expect(number_to_percentage(99.9, precision: 1, locale: :en)).to eq("99.9%")
    end
  end

  describe "elenchi dentro una frase" do
    it "unisce due parole con la e" do
      expect([ "Scadenza", "Assegnatario" ].to_sentence(locale: :it)).to eq("Scadenza e Assegnatario")
    end

    it "chiude un elenco lungo con la e, senza virgola prima" do
      expect([ "Scadenza", "Assegnatario", "Progetto" ].to_sentence(locale: :it))
        .to eq("Scadenza, Assegnatario e Progetto")
    end

    it "l'inglese resta con and" do
      expect([ "a", "b" ].to_sentence(locale: :en)).to eq("a and b")
    end
  end

  # CYRA-568 — il difetto peggiore non era il formato ma la discordanza: nella stessa pagina dei
  # registri lo stesso numero era scritto «4.029», «4031» e ancora «4031». I conteggi delle liste
  # passano tutti dagli stessi due punti (il conteggio della toolbar e il piede di paginazione):
  # `count: t(...)` grezzo o un intero nudo rimettono in pagina la seconda forma.
  describe "conteggi delle liste" do
    def scan(glob: "app/views/**/*.erb", &condizione)
      Dir.glob(Rails.root.join(glob)).filter_map do |file|
        righe = File.readlines(file).each_with_index.select { |riga, _| condizione.call(riga) }
        righe.map { |_riga, i| "#{Pathname(file).relative_path_from(Rails.root)}:#{i + 1}" } if righe.any?
      end.flatten
    end

    it "nessuna toolbar riceve un conteggio tradotto senza passare dall'helper" do
      expect(scan { |riga| riga.match?(/^\s*count: t\(/) }).to be_empty
    end

    # Il totale della paginazione passato nudo: legittimo dentro `t(..., count:)` (serve alla
    # pluralizzazione, e da lì lo formatta `count_label`), mai come valore stampato in pagina.
    it "nessuna toolbar riceve il totale della paginazione come numero nudo" do
      expect(scan { |riga| riga.match?(/count: @pagination\.total/) && !riga.include?("t(") }).to be_empty
    end
  end
end
