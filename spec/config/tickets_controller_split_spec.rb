# frozen_string_literal: true

require "rails_helper"

# CYRA-739 — la pagina dei ticket era governata da un file solo: 1.328 righe, ventiquattro azioni e
# sessanta metodi privati che facevano tutto, dalla ricerca testuale e semantica alla bacheca, dai
# doppioni alle opzioni del modulo. Un file che fa tutto è un file che si tocca sempre: la correzione
# della ricerca, quella della bacheca e quella del modulo finivano nello stesso posto, e ogni
# modifica arrivava in mezzo al lavoro di qualcun altro.
#
# Qui si guarda il SORGENTE, non il comportamento: che le parti esistano davvero e che il file
# principale non se le sia riprese. Le prove di comportamento restano i request spec della pagina
# (spec/requests/member/tickets/), che sono la rete vera di questa divisione.
RSpec.describe "La pagina dei ticket non è governata da un file solo", type: :model do
  # Il tetto della Definition of Done. Non è un numero estetico: sopra questa misura il file torna a
  # essere il posto in cui finisce tutto, che è esattamente il problema.
  let(:tetto_righe) { 300 }
  let(:controller_path) { Rails.root.join("app/controllers/member/tickets_controller.rb") }
  # Solo le righe di CODICE: un commento che NOMINA la ricerca o la bacheca è memoria utile e resta
  # dov'è: quello che non deve tornare qui è la regola scritta di nuovo.
  let(:codice) { controller_path.readlines.reject { |riga| riga.strip.start_with?("#") } }

  it "il file principale sta sotto le trecento righe" do
    righe = controller_path.readlines.size

    expect(righe).to be <= tetto_righe,
                     "app/controllers/member/tickets_controller.rb misura #{righe} righe (tetto #{tetto_righe}): " \
                     "quello che è tornato dentro va in una parte con un compito suo."
  end

  # Le quattro parti nominate dal ticket, ciascuna con il proprio compito. Sono classi vere e non
  # metodi spostati altrove: chi cambia la ricerca apre la ricerca, chi cambia la bacheca apre la
  # bacheca.
  it "ogni parte estratta esiste ed è caricabile" do
    expect(defined?(Ticketing::Search::Query)).to eq("constant")
    expect(defined?(Ticketing::BoardScope)).to eq("constant")
    expect(defined?(Ticketing::DedupPresenter)).to eq("constant")
    expect(defined?(Ticketing::FormOptions)).to eq("constant")
  end

  # Le grafie che dicono «la logica è tornata nel controller». Non sono divieti di stile: ognuna è il
  # cuore di una delle parti estratte, e ritrovarla qui significa che ne esistono di nuovo due copie.
  {
    "la ricerca (ILIKE, ordinamento per pertinenza, confine di parola sul codice)" =>
      [ "ILIKE", "in_order_of", "SemanticSearch" ],
    "le colonne della bacheca (finestra del concluso, blocco di card)" =>
      [ "BOARD_DONE_WINDOW", "BOARD_COLUMN_PAGE" ],
    "le opzioni del modulo (mappa progetto→piattaforme, piattaforme preselezionate dal profilo)" =>
      [ "ProjectPlatform", "platform_codes" ],
    "i doppioni (soglie di somiglianza, testo del confronto)" =>
      [ "DUPLICATE_PANEL_SIMILARITY", "DUPLICATE_GATE_SIMILARITY", "FindSimilarTickets" ]
  }.each do |compito, grafie|
    it "il file principale non riscrive più #{compito}" do
      tornate = grafie.select { |grafia| codice.any? { |riga| riga.include?(grafia) } }

      expect(tornate).to be_empty,
                         "Queste grafie sono tornate nel controller: #{tornate.join(', ')}. " \
                         "Vivono nella parte che ha quel compito, non qui."
    end
  end
end
