# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::UpdateIdea, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  it "aggiorna titolo, problema, soluzione e stakeholder di un'idea aperta" do
    result = described_class.call(idea:, params: { title: "Nuovo titolo", problem: "Nuovo problema",
                                                   solution: "Nuova soluzione", stakeholders: [ "Team A" ] })

    expect(result).to be_ok
    expect(idea.reload.title).to eq("Nuovo titolo")
    expect(idea.problem).to eq("Nuovo problema")
    expect(idea.solution).to eq("Nuova soluzione")
    expect(idea.stakeholders).to eq([ "Team A" ])
  end

  # CYRA-167 — l'indice segue il testo scritto, non ogni salvataggio: ri-embeddare quando cambiano
  # solo gli stakeholder sarebbe una chiamata di rete per niente.
  it "ri-indicizza quando cambia il testo dell'idea" do
    expect do
      described_class.call(idea:, params: { title: "Titolo cambiato", problem: idea.problem,
                                            solution: idea.solution })
    end.to have_enqueued_job(Ideas::EmbedIdeaJob).with(idea_id: idea.id)
  end

  it "NON ri-indicizza quando cambiano solo gli stakeholder" do
    expect do
      described_class.call(idea:, params: { title: idea.title, problem: idea.problem,
                                            solution: idea.solution, stakeholders: [ "Team A" ] })
    end.not_to have_enqueued_job(Ideas::EmbedIdeaJob)
  end

  it "registra 'updated' coi campi cambiati, con actor/true_actor threadati (impersonation)" do
    god = create(:account)

    expect do
      result = described_class.call(idea:, params: { title: "Nuovo titolo", problem: idea.problem },
                                    actor: idea.author, true_actor: god)
      expect(result).to be_ok
    end.to change(Activity::Event, :count).by(1)

    event = idea.activity_events.chronological.last
    expect(event.action).to eq("updated")
    expect(event.data["fields"]).to include("title")
    expect(event.actor).to eq(idea.author)
    expect(event.true_actor).to eq(god)
    expect(event).to be_impersonated
  end

  # I params vanno passati TUTTI: title/problem/solution sono full replace (contratto PUT della CLI,
  # vedi Cli::V1::IdeasController#update), quindi ometterne uno lo svuota — che è una modifica vera e
  # un evento legittimo. "Non cambia nulla" si prova rimandando i valori correnti.
  it "NON registra eventi se non cambia nulla (niente rumore)" do
    expect do
      described_class.call(idea:, params: { title: idea.title, problem: idea.problem,
                                            solution: idea.solution })
    end.not_to change(Activity::Event, :count)
  end

  it "idea archiviata (congelata) → R422-IDEA-002 e nessuna modifica" do
    frozen = create(:idea, :archived, organization:, project:, title: "Originale")

    result = described_class.call(idea: frozen, params: { title: "Cambiato", problem: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
    expect(frozen.reload.title).to eq("Originale")
  end

  it "idea convertita (congelata) → R422-IDEA-002" do
    frozen = create(:idea, :converted, organization:, project:)

    result = described_class.call(idea: frozen, params: { title: "Cambiato", problem: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
  end

  it "validazione fallita (titolo vuoto) → R422-IDEA-001 con details" do
    result = described_class.call(idea:, params: { title: "  ", problem: "corpo" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-001")
    expect(result.error.details).to have_key(:title)
  end

  # CYRA-845
  it "aggiorna monetizzazione e rischi" do
    idea = create(:idea, organization: create(:organization))
    result = described_class.call(idea:, params: { title: idea.title, problem: idea.problem,
                                                   solution: idea.solution, monetization: "Boost",
                                                   risks: "Moderazione" })
    expect(result).to be_ok
    expect(idea.reload).to have_attributes(monetization: "Boost", risks: "Moderazione")
  end
end
