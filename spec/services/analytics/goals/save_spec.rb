# frozen_string_literal: true

require "rails_helper"

# Un goal è la definizione di cosa conta come conversione: nasce sempre dentro un progetto e le sue
# regole (nome, bersaglio, unicità) sono sul model. Qui si prova che il service le rispetti e che un
# rifiuto arrivi come errore di dominio — non come eccezione né come Result ok con un record mai salvato.
RSpec.describe Analytics::Goals::Save do
  let(:project) { create(:project) }

  it "crea un goal su visita pagina e lo lega al progetto" do
    result = described_class.call(project:, attributes: { kind: :pageview_path, path_pattern: "/pricing",
                                                          display_name: "Visita pricing" })

    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(result.value.project).to eq(project)
    expect(project.analytics_goals.reload.map(&:path_pattern)).to eq([ "/pricing" ])
  end

  it "crea un goal su evento personalizzato" do
    result = described_class.call(project:, attributes: { kind: :custom_event, event_name: "Signup",
                                                          display_name: "Iscrizione" })

    expect(result).to be_ok
    expect(result.value.event_name).to eq("Signup")
    expect(result.value).to be_custom_event
  end

  it "senza nome visibile rifiuta e non salva niente" do
    result = described_class.call(project:, attributes: { kind: :pageview_path, path_pattern: "/x",
                                                          display_name: "  " })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GOAL-001")
    expect(result.error.details).to have_key(:display_name)
    expect(project.analytics_goals.reload).to be_empty
  end

  it "lo stesso bersaglio due volte nello stesso progetto è un errore, non un doppione" do
    described_class.call(project:, attributes: { kind: :pageview_path, path_pattern: "/pricing",
                                                 display_name: "Primo" })

    result = described_class.call(project:, attributes: { kind: :pageview_path, path_pattern: "/pricing",
                                                          display_name: "Secondo" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GOAL-001")
    expect(project.analytics_goals.reload.count).to eq(1)
  end

  it "lo stesso bersaglio in un ALTRO progetto è legittimo: l'unicità è per progetto" do
    described_class.call(project:, attributes: { kind: :pageview_path, path_pattern: "/pricing",
                                                 display_name: "Primo" })

    result = described_class.call(project: create(:project),
                                  attributes: { kind: :pageview_path, path_pattern: "/pricing",
                                                display_name: "Primo" })

    expect(result).to be_ok
  end
end
