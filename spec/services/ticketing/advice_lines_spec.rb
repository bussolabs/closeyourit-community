# frozen_string_literal: true

require "rails_helper"

# Il parser che trasforma la sezione `**Consigli:**` in righe cliccabili (CYRA-264). Sbagliare qui
# non produce un errore visibile: produce il titolo sbagliato su un ticket nuovo, oppure fa sparire
# in silenzio un consiglio che qualcuno aveva scritto. Per questo è un PORO puro e testato da solo,
# prima ancora della vista che lo mostra.
#
# Il contratto è quello scritto in knowledge-base/global/closeyourit-writing.md e ricontrollato da
# skills/shared/scripts/text-check.mjs nel repo delle skill: elenco puntato, una riga per consiglio,
# la sezione finisce alla prima riga vuota o alla prossima etichetta. Se cambia lì, cambia qui.
RSpec.describe Ticketing::AdviceLines do
  def lines_of(text) = described_class.call(text: text)

  describe "quando la sezione c'è ed è scritta bene" do
    it "restituisce una riga per consiglio, senza il trattino" do
      text = <<~MD
        **Fatto:** tutto a posto.

        **Consigli:**
        - Il contatore manca sulla casella del resoconto.
        - presentforme ha lo stesso gate di coverage che ha rotto eketo.
      MD

      expect(lines_of(text)).to eq([
        "Il contatore manca sulla casella del resoconto.",
        "presentforme ha lo stesso gate di coverage che ha rotto eketo."
      ])
    end

    it "accetta l'asterisco come segno di elenco, non solo il trattino" do
      expect(lines_of("**Consigli:**\n* Un consiglio scritto con l'asterisco.")).to eq([ "Un consiglio scritto con l'asterisco." ])
    end

    it "tollera l'indentazione davanti al trattino" do
      expect(lines_of("**Consigli:**\n  - Un consiglio rientrato di due spazi.")).to eq([ "Un consiglio rientrato di due spazi." ])
    end
  end

  describe "dove finisce la sezione" do
    # La riga vuota chiude: quel che viene dopo è un altro discorso, non un consiglio in più.
    it "si ferma alla prima riga vuota" do
      text = "**Consigli:**\n- Il primo consiglio, quello vero.\n\n- Questo non fa più parte della sezione."

      expect(lines_of(text)).to eq([ "Il primo consiglio, quello vero." ])
    end

    it "si ferma alla prossima etichetta" do
      text = "**Consigli:**\n- Il consiglio da raccogliere.\n**Rischi:** qualcosa può rompersi."

      expect(lines_of(text)).to eq([ "Il consiglio da raccogliere." ])
    end

    it "legge fino in fondo quando la sezione è l'ultima" do
      text = "**Fatto:** fatto.\n\n**Consigli:**\n- Primo.\n- Secondo."

      expect(lines_of(text).length).to eq(2)
    end
  end

  describe "quando non c'è niente da raccogliere" do
    it "restituisce vuoto se la sezione non c'è" do
      expect(lines_of("**Fatto:** solo questo.")).to eq([])
    end

    it "restituisce vuoto per testo nil o vuoto" do
      expect(lines_of(nil)).to eq([])
      expect(lines_of("   ")).to eq([])
    end

    # Una sezione scritta come paragrafo NON viene indovinata: spezzarla a caso produrrebbe titoli
    # senza senso su ticket veri. Meglio non mostrare nulla — text-check.mjs avvisa già chi scrive.
    it "ignora una sezione senza elenco puntato invece di indovinare" do
      expect(lines_of("**Consigli:**\nBisognerebbe sistemare anche gli altri host della fleet.")).to eq([])
    end

    it "ignora le righe di elenco vuote" do
      expect(lines_of("**Consigli:**\n-\n- Un consiglio vero.")).to eq([ "Un consiglio vero." ])
    end
  end

  describe "difese" do
    # Un resoconto da ventimila caratteri pieno di trattini non deve diventare cento link: oltre il
    # tetto la sezione non è più un elenco di consigli, è un dump.
    it "non restituisce più consigli del massimo previsto" do
      text = "**Consigli:**\n#{Array.new(50) { |i| "- Consiglio numero #{i} scritto per intero." }.join("\n")}"

      expect(lines_of(text).length).to eq(described_class::MAX_LINES)
    end

    # Il titolo del ticket ha un tetto di 255 caratteri: una riga più lunga arriva troncata invece di
    # far fallire la creazione dopo che l'utente ha già compilato il form.
    it "tronca una riga più lunga del titolo di un ticket" do
      long = "x" * 400

      expect(lines_of("**Consigli:**\n- #{long}").first.length).to eq(described_class::MAX_LINE_CHARS)
    end
  end
end
