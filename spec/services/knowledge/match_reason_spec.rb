# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::MatchReason do
  def page(title:, body: "", tags: [])
    Knowledge::Page.new(title: title, body: body, tags: tags)
  end

  it "il motivo sono i termini del titolo che compaiono anche nel testo del record" do
    reason = described_class.call(page: page(title: "Runbook errori di login"),
                                  text: "Il login non funziona dopo il rilascio")

    expect(reason.terms).to eq([ "login" ])
    expect(reason.section).to be_nil
  end

  it "aggancia singolare e plurale dello stesso termine" do
    reason = described_class.call(page: page(title: "Guida agli errori di rete"),
                                  text: "Errore di rete in produzione")

    expect(reason.terms).to eq(%w[errori rete])
  end

  it "mostra al massimo tre termini, nell'ordine del titolo" do
    reason = described_class.call(page: page(title: "Backup, ripristino, replica e conservazione"),
                                  text: "Il backup non parte: replica ferma, ripristino lento, conservazione a rischio")

    expect(reason.terms).to eq(%w[backup ripristino replica])
  end

  it "aggancia anche le etichette della pagina" do
    reason = described_class.call(page: page(title: "Manuale", tags: [ "flutter" ]),
                                  text: "La compilazione flutter fallisce")

    expect(reason.terms).to eq([ "flutter" ])
  end

  it "le parole comuni e quelle troppo corte non agganciano nulla" do
    reason = described_class.call(page: page(title: "Quando serve questo documento"),
                                  text: "Quando serve, non ho capito bene se e come")

    expect(reason).to be_nil
  end

  it "senza aggancio nel titolo, indica la sezione del contenuto che ne parla" do
    body = "Premessa generale.\n\n## Ripristino del database\nI passi da seguire.\n\n## Contatti\nChi chiamare."
    reason = described_class.call(page: page(title: "Manuale operativo", body: body),
                                  text: "Il ripristino del database è lentissimo")

    expect(reason.terms).to be_empty
    expect(reason.section).to eq("Ripristino del database")
  end

  it "nessun termine e nessuna sezione in comune → nessun motivo" do
    reason = described_class.call(page: page(title: "Palette dei colori", body: "Tinte, contrasti, gradazioni."),
                                  text: "Il login non funziona dopo il rilascio")

    expect(reason).to be_nil
  end

  it "ignora gli accenti nel confronto" do
    reason = described_class.call(page: page(title: "Attività pianificate"),
                                  text: "Le attivita non partono più")

    expect(reason.terms).to eq([ "attività" ])
  end
end
