# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::SystemPrompt do
  let(:catalog) do
    [
      Assistant::BuildCatalog::Function.new(key: "tickets", label: "Ticket", description: "Segnala bug.", path: "/member/tickets"),
      Assistant::BuildCatalog::Function.new(key: "ideas",   label: "Idee",   description: "Proponi idee.", path: "/member/ideas")
    ]
  end

  subject(:prompt) { described_class.call(catalog: catalog) }

  it "elenca ogni funzione con etichetta, descrizione e percorso cliccabile" do
    expect(prompt).to include("Ticket", "Segnala bug.", "/member/tickets")
    expect(prompt).to include("Idee", "Proponi idee.", "/member/ideas")
  end

  it "vincola l'assistente a usare SOLO le funzioni e i percorsi dell'elenco (anti-allucinazione)" do
    expect(prompt).to match(/\bsolo\b/i)
  end

  it "istruisce a rispondere nella lingua dell'utente, in modo semplice e senza gergo" do
    expect(prompt.downcase).to match(/lingua.*utente|stessa lingua/)
    expect(prompt.downcase).to include("semplice")
  end

  it "dichiara che l'assistente non esegue azioni ma spiega soltanto" do
    expect(prompt.downcase).to match(/non eseg|solo.*spieg|spieg/)
  end

  # CYRA-436 — l'assistente citava l'indirizzo della pagina al posto del suo nome e i bottoni senza
  # dire come si chiamano. Il prompt ora impone il nome della destinazione e vieta il percorso grezzo.
  it "impone la forma [Nome](/percorso) col nome visibile e vieta il percorso grezzo come testo" do
    expect(prompt).to include("[Nome]")
    expect(prompt.downcase).to match(/mai.*percorso|percorso.*grezzo|non scrivere.*percorso/)
  end

  # Il catalogo dà solo nome/descrizione/percorso della PAGINA, non le etichette dei bottoni interni:
  # imporre "la label esatta del bottone" spingerebbe il modello a inventarla. Il prompt lo vieta.
  it "non impone un'etichetta esatta per i bottoni interni (non sono nel catalogo): li fa descrivere senza inventare" do
    expect(prompt.downcase).to match(/bottone|pulsante/)
    expect(prompt.downcase).to match(/non inventare/)
  end
end
