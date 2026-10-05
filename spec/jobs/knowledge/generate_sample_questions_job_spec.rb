# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::GenerateSampleQuestionsJob, type: :job do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  it "semina una domanda per ogni pagina pubblicata del progetto, dalla più recente" do
    old_page = create(:knowledge_page, project: project, title: "Vecchia", updated_at: 2.days.ago)
    new_page = create(:knowledge_page, :decision, project: project, title: "Recente", updated_at: 1.hour.ago)

    described_class.new.perform

    seeds = Knowledge::SampleQuestion.for_projects([ project.id ]).ordered
    expect(seeds.map(&:title)).to eq(%w[Recente Vecchia])
    expect(seeds.map(&:position)).to eq([ 0, 1 ])
    expect(seeds.first.kind).to eq("decision")
    expect(seeds.first.knowledge_page_id).to eq(new_page.id)
    expect(seeds.last.knowledge_page_id).to eq(old_page.id)
  end

  it "non supera il tetto per progetto" do
    create_list(:knowledge_page, Knowledge::Constants::SAMPLE_QUESTIONS_PER_PROJECT + 2, project: project)

    described_class.new.perform

    expect(Knowledge::SampleQuestion.for_projects([ project.id ]).count)
      .to eq(Knowledge::Constants::SAMPLE_QUESTIONS_PER_PROJECT)
  end

  it "ignora le pagine in revisione, scartate e org-wide (senza progetto)" do
    create(:knowledge_page, :in_review, project: project, title: "Proposta")
    create(:knowledge_page, :org_wide, organization: org, title: "Generale")
    create(:knowledge_page, project: project, title: "Pubblicata")

    described_class.new.perform

    titles = Knowledge::SampleQuestion.for_projects([ project.id ]).pluck(:title)
    expect(titles).to eq([ "Pubblicata" ])
  end

  it "è idempotente: rieseguirlo non duplica i semi" do
    create(:knowledge_page, project: project, title: "Unica")

    described_class.new.perform
    described_class.new.perform

    expect(Knowledge::SampleQuestion.for_projects([ project.id ]).count).to eq(1)
  end

  it "ripulisce i semi di un progetto che non ha più pagine" do
    stale = create(:knowledge_sample_question, project: project, title: "Orfana")

    described_class.new.perform

    expect(Knowledge::SampleQuestion.exists?(stale.id)).to be(false)
  end
end
