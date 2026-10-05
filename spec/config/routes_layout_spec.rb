# frozen_string_literal: true

require "rails_helper"

# CYRA-708: tutte le rotte stavano in un solo `config/routes.rb` da 1.572 righe — sito pubblico,
# area utenti, API, riga di comando e pannello god uno sotto l'altro. Ora ogni canale ha il suo file
# sotto `config/routes/`, e `config/routes.rb` li elenca soltanto.
#
# Lo split è a rischio zero SOLO se l'ordine resta quello di prima: Rails serve la PRIMA rotta che
# combacia, quindi spostare un blocco davanti a un altro cambia chi risponde senza cambiare una sola
# riga di codice, e la suite normale non se ne accorge (le rotte in conflitto rispondono comunque,
# solo dal controller sbagliato). Questa prova presidia le precedenze che i commenti in
# `config/routes/*.rb` dichiarano fragili, e l'invariante che tiene i file separati nel tempo.
RSpec.describe "config/routes" do
  # L'ordine di questo elenco È l'ordine di dichiarazione delle rotte: rispecchia i blocchi del file
  # unico da cui vengono. Riordinarlo qui senza riordinare `config/routes.rb` fa fallire la prova.
  let(:aree) { %i[service webhooks ai_gateway api cli account valhalla member website errors] }

  let(:sorgente) { File.read(Rails.root.join("config/routes.rb")) }

  # Le sole righe che contano: né vuote, né commenti, né l'apertura/chiusura del blocco `draw`.
  let(:istruzioni) do
    sorgente.lines.map(&:strip).reject do |riga|
      riga.empty? || riga.start_with?("#") || riga == "Rails.application.routes.draw do" || riga == "end"
    end
  end

  let(:rotte) { Rails.application.routes.routes.to_a }

  # Posizione della prima rotta che combacia con il path indicato. `nil` non è ammesso: una prova che
  # confronta due `nil` passerebbe anche con la rotta sparita.
  def posizione(prefisso_path)
    indice = rotte.index { |rotta| rotta.path.spec.to_s.start_with?(prefisso_path) }
    expect(indice).not_to be_nil, "nessuna rotta dichiarata su #{prefisso_path}"
    indice
  end

  def posizione_di(nome)
    indice = rotte.index { |rotta| rotta.name == nome.to_s }
    expect(indice).not_to be_nil, "la rotta #{nome} non esiste più"
    indice
  end

  describe "config/routes.rb" do
    it "non dichiara rotte: elenca soltanto i file di area" do
      non_draw = istruzioni.reject { |riga| riga.match?(/\Adraw\(:[a-z_]+\)\z/) }

      expect(non_draw).to be_empty, <<~MESSAGGIO
        Queste righe dichiarano rotte dentro `config/routes.rb`, che deve restare il solo indice
        delle aree. Spostale nel file dell'area a cui appartengono, nella stessa posizione:

        #{non_draw.join("\n")}
      MESSAGGIO
    end

    it "elenca le aree nell'ordine in cui erano dichiarate nel file unico" do
      elencate = istruzioni.filter_map { |riga| riga[/\Adraw\(:([a-z_]+)\)\z/, 1]&.to_sym }

      expect(elencate).to eq(aree)
    end

    it "dà a ogni area un file esistente" do
      mancanti = aree.reject { |area| Rails.root.join("config/routes/#{area}.rb").exist? }

      expect(mancanti).to be_empty, "aree elencate senza file: #{mancanti.join(', ')}"
    end

    # Un file dentro `config/routes/` che nessuno `draw` nomina non produce nessuna rotta e non
    # solleva nessun errore: le sue pagine danno 404 e il file sembra a posto.
    it "non lascia file di rotte scollegati" do
      su_disco = Dir.glob(Rails.root.join("config/routes/*.rb")).map { |path| File.basename(path, ".rb").to_sym }

      expect(su_disco.sort).to eq(aree.sort)
    end
  end

  describe "l'ordine di dichiarazione fra le aree" do
    # L'apex `closeyour.it` deve mandare al canonico `www` qualunque indirizzo, compresa la home:
    # dopo la root del sito non vedrebbe mai "/".
    it "mette il redirect dell'apex prima della root del sito" do
      expect(posizione("/(*path)")).to be < posizione_di(:website_root)
    end

    # Il catch-all rende la 404 di prodotto: davanti a una rotta vera se la mangerebbe.
    it "mette il catch-all dell'area utenti dopo ogni altra rotta /member" do
      catch_all = posizione("/member/*path")
      altre = rotte.each_index.select do |indice|
        path = rotte[indice].path.spec.to_s
        path.start_with?("/member") && !path.start_with?("/member/*path")
      end

      expect(altre.max).to be < catch_all
    end

    # `/status/g/acme/servizi` combacia ANCHE con la per-monitor a tre segmenti (org "g"): a
    # disambiguare è l'ordine, non i constraints.
    it "mette la status page di gruppo prima di quella del singolo monitor" do
      expect(posizione_di(:public_group_status)).to be < posizione_di(:public_status)
      expect(posizione_di(:public_group_status_badge)).to be < posizione_di(:public_status_badge)
    end

    # Le pagine di errore sono servite da `config.exceptions_app` e non devono precedere nulla.
    it "mette le pagine di errore in fondo alle rotte dell'applicazione" do
      expect(posizione("/404")).to be > posizione_di(:website_root)
      expect(posizione("/500")).to be > posizione("/member/*path")
    end
  end
end
