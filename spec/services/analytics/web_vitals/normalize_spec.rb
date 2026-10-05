# frozen_string_literal: true

require "rails_helper"

# CYRA-538 — questo normalizzatore riceve quello che manda un browser di qualcun altro: un client
# scritto in casa, una versione vecchia, o qualcuno che prova. Non deve mai sollevare, e non deve mai
# far entrare un valore che sposterebbe il percentile di un sito intero.
RSpec.describe Analytics::WebVitals::Normalize do
  def normalizza(payload) = described_class.call(payload:)

  it "tiene la misura, la metrica e l'indirizzo, e ricalcola l'esito" do
    esito = normalizza({ "metric" => "LCP", "value" => 2_400, "hostname" => "ACME.example",
                         "path" => "/prezzi", "occurred_at" => Time.current.iso8601 })

    expect(esito.metric).to eq("lcp")
    expect(esito.hostname).to eq("acme.example")
    expect(esito.value).to eq(2_400.0)
    expect(esito.rating).to eq("good")
  end

  it "un payload che non è nemmeno un oggetto non fa saltare niente" do
    expect { normalizza("spazzatura") }.not_to raise_error
    expect(normalizza(nil).metric).to eq("")
  end

  describe "il valore" do
    it "un valore che non è un numero non entra" do
      expect(normalizza({ "metric" => "lcp", "value" => "molto lento" }).value).to be_nil
    end

    it "un valore negativo non entra: nessuna pagina compare prima di essere chiesta" do
      expect(normalizza({ "metric" => "lcp", "value" => -12 }).value).to be_nil
    end

    # Basta una manciata di misure assurde per spostare il percentile di un sito intero: fuori tetto
    # si scarta la misura, non si prova a salvarla arrotondandola.
    it "un valore fuori da ogni scala non entra, con la scala giusta per ogni metrica" do
      expect(normalizza({ "metric" => "lcp", "value" => 999_999 }).value).to be_nil
      expect(normalizza({ "metric" => "cls", "value" => 50 }).value).to be_nil
      # Il CLS è adimensionale: 3 è pessimo ma plausibile, e deve passare.
      expect(normalizza({ "metric" => "cls", "value" => 3 }).value).to eq(3.0)
    end

    it "un numero mandato come stringa è comunque un numero" do
      expect(normalizza({ "metric" => "lcp", "value" => "2400.5" }).value).to eq(2_400.5)
    end
  end

  describe "l'indirizzo" do
    it "la query non viaggia: se arriva, si tronca" do
      expect(normalizza({ "path" => "/cerca?q=scarpe#risultati" }).path).to eq("/cerca")
    end

    it "un percorso senza barra iniziale la riceve" do
      expect(normalizza({ "path" => "prezzi" }).path).to eq("/prezzi")
    end

    it "un percorso vuoto resta vuoto, e la misura verrà scartata più avanti" do
      expect(normalizza({ "path" => "   " }).path).to eq("")
    end
  end

  describe "il tipo di navigazione" do
    it "tiene quelli che conosciamo" do
      expect(normalizza({ "navigation_type" => "back-forward" }).navigation_type).to eq("back-forward")
    end

    # Un tipo inventato non si conserva: sarebbe un valore su cui poi qualcuno filtrerebbe,
    # trovando risultati che non vogliono dire niente.
    it "scarta quelli che non conosciamo invece di conservarli" do
      expect(normalizza({ "navigation_type" => "teletrasporto" }).navigation_type).to be_nil
    end
  end

  # L'esito lo decide il server: fidarsi di quello del client vorrebbe dire lasciare che sia il
  # misurato a darsi il voto, e un client con soglie vecchie vedrebbe verde dove Google vede rosso.
  it "ignora l'esito mandato dal client e ricalcola il proprio" do
    esito = normalizza({ "metric" => "lcp", "value" => 9_000, "rating" => "good" })

    expect(esito.rating).to eq("poor")
  end

  it "una metrica che non conosciamo non riceve un esito di comodo" do
    expect(normalizza({ "metric" => "inventata", "value" => 10 }).rating).to be_nil
  end
end
