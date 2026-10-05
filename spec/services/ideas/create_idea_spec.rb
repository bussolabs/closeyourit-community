# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::CreateIdea, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end

  # CYRA-147: la creazione accoda l'avviso idea_created escludendo l'autore (actor_id).
  it "accoda l'avviso idea_created con l'autore escluso" do
    expect do
      described_class.call(organization:, author: owner,
                           params: { project_id: project.id, title: "Dark mode", problem: "y",
                                     solution: "Tema scuro", stakeholders: [] })
    end.to have_enqueued_job(Alerting::EvaluateJob).with(
      hash_including(event_type: "idea_created", subject_type: "Ideas::Idea",
                     project_id: project.id, actor_id: owner.id)
    )
  end

  # CYRA-167: l'idea entra subito nell'indice, così la ricerca per significato e il suggerimento dei
  # doppioni la conoscono senza aspettare il giro notturno.
  it "accoda l'indicizzazione dell'idea appena creata" do
    result = nil
    expect do
      result = described_class.call(organization:, author: owner,
                                    params: { project_id: project.id, title: "Esportare in PDF",
                                              problem: "I clienti chiedono il PDF" })
    end.to have_enqueued_job(Ideas::EmbedIdeaJob)

    expect(enqueued_jobs.filter_map { |job| job["arguments"].first["idea_id"] if job["job_class"] == "Ideas::EmbedIdeaJob" })
      .to eq([ result.value.id ])
  end

  it "non accoda l'indicizzazione se l'idea non viene creata" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }

    expect do
      described_class.call(organization:, author: member, params: { project_id: project.id, title: "x", problem: "y" })
    end.not_to have_enqueued_job(Ideas::EmbedIdeaJob)
  end

  it "non accoda alcun avviso se l'idea non viene creata (progetto non accessibile)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
    expect do
      described_class.call(organization:, author: member, params: { project_id: project.id, title: "x", problem: "y" })
    end.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "crea l'idea sul progetto visibile con autore = chi propone" do
    result = described_class.call(organization:, author: owner,
                                  params: { project_id: project.id, title: "Dark mode",
                                            problem: "La dashboard acceca di notte",
                                            solution: "Tema scuro",
                                            stakeholders: [ "Team Mobile", "Team Mobile", "" ] })

    expect(result).to be_ok
    idea = result.value
    expect(idea).to be_persisted
    expect(idea.author).to eq(owner)
    expect(idea.project).to eq(project)
    expect(idea).to be_status_open
    expect(idea.problem).to eq("La dashboard acceca di notte")
    expect(idea.solution).to eq("Tema scuro")
    expect(idea.stakeholders).to eq([ "Team Mobile" ])
  end

  it "member senza link al progetto → R404-IDEA-001 (anti-BOLA, strict scoping)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }

    result = described_class.call(organization:, author: member,
                                  params: { project_id: project.id, title: "x", problem: "y" })

    expect(result).to be_err
    expect(result.error.code).to eq("R404-IDEA-001")
  end

  it "progetto di un'altra org → R404-IDEA-001" do
    other_project = create(:project)

    result = described_class.call(organization:, author: owner,
                                  params: { project_id: other_project.id, title: "x", problem: "y" })

    expect(result).to be_err
    expect(result.error.code).to eq("R404-IDEA-001")
  end

  it "registra un evento 'created' nell'activity-log generalizzato" do
    expect do
      result = described_class.call(organization:, author: owner,
                                    params: { project_id: project.id, title: "x", problem: "y" })
      expect(result).to be_ok

      event = result.value.activity_events.last
      expect(event.action).to eq("created")
      expect(event.actor).to eq(owner)
      expect(event.organization_id).to eq(organization.id)
    end.to change(Activity::Event, :count).by(1)
  end

  it "validazione fallita → nessun evento orfano (rollback atomico)" do
    expect do
      described_class.call(organization:, author: owner,
                           params: { project_id: project.id, title: "x", problem: "  " })
    end.not_to change(Activity::Event, :count)
  end

  it "validazione fallita (problema vuoto) → R422-IDEA-001 con details" do
    result = described_class.call(organization:, author: owner,
                                  params: { project_id: project.id, title: "x", problem: "  " })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-001")
    expect(result.error.details).to have_key(:problem)
  end

  # CYRA-845 — monetizzazione e rischi sono campi dell'idea; un'evoluzione nasce già collegata.
  describe "monetizzazione, rischi ed evoluzione" do
    it "salva monetizzazione e rischi" do
      result = described_class.call(organization:, author: owner,
                                    params: { project_id: project.id, title: "Boost", problem: "y",
                                              monetization: "Acquisto singolo", risks: "Serve Stripe" })
      expect(result).to be_ok
      expect(result.value).to have_attributes(monetization: "Acquisto singolo", risks: "Serve Stripe")
    end

    it "con evolves_id nasce come evoluzione dell'idea di base" do
      base = create(:idea, organization:, project:)
      result = described_class.call(organization:, author: owner,
                                    params: { project_id: project.id, title: "Tavoli", problem: "y",
                                              evolves_id: base.id })
      expect(result).to be_ok
      expect(result.value.parent).to eq(base)
      expect(base.reload.evolutions).to eq([ result.value ])
    end

    it "evolves_id di un altro progetto → 404 R404-IDEA-002 e nessuna idea creata" do
      foreign = create(:idea, organization:)
      expect do
        result = described_class.call(organization:, author: owner,
                                      params: { project_id: project.id, title: "x", problem: "y",
                                                evolves_id: foreign.id })
        expect(result.error.code).to eq("R404-IDEA-002")
      end.not_to change(Ideas::Idea, :count)
    end

    it "evolvere un'idea che è già un'evoluzione → 422 e nessuna idea creata (un solo livello)" do
      base = create(:idea, organization:, project:)
      child = create(:idea, organization:, project:)
      create(:idea_link, :evolution, source: child, target: base)
      expect do
        result = described_class.call(organization:, author: owner,
                                      params: { project_id: project.id, title: "x", problem: "y",
                                                evolves_id: child.id })
        expect(result.error.code).to eq("R422-IDEA-001")
        expect(result.error.details).to have_key(:target)
      end.not_to change(Ideas::Idea, :count)
    end
  end
end
