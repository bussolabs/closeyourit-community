# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::SampleQuestion, type: :model do
  it "la factory è valida" do
    expect(build(:knowledge_sample_question)).to be_valid
  end

  it "richiede un titolo" do
    expect(build(:knowledge_sample_question, title: nil)).to be_invalid
  end

  describe "#question" do
    it "compone la domanda dal titolo reale e dal template del tipo (via i18n)" do
      sample = build(:knowledge_sample_question, :decision, title: "Scelta del database")

      expect(sample.question).to eq(I18n.t("member.knowledge.ask.samples.decision", title: "Scelta del database"))
      expect(sample.question).to include("Scelta del database")
    end

    it "cambia template a seconda del tipo di pagina" do
      title = "Deploy con Kamal"
      note = build(:knowledge_sample_question, title: title, kind: :note).question
      guide = build(:knowledge_sample_question, :guide, title: title).question

      # Titolo reale in entrambe, ma la cornice della domanda è diversa: nasce dal tipo, non è fissa.
      expect(note).to include(title)
      expect(guide).to include(title)
      expect(note).not_to eq(guide)
    end
  end

  describe "scope" do
    it ".for_projects filtra sui soli progetti passati" do
      keep = create(:knowledge_sample_question)
      drop = create(:knowledge_sample_question)

      expect(described_class.for_projects([ keep.project_id ])).to contain_exactly(keep)
      expect(described_class.for_projects([ keep.project_id ])).not_to include(drop)
    end

    it ".ordered mette prima la position più bassa" do
      project = create(:project)
      second = create(:knowledge_sample_question, project: project, position: 1)
      first = create(:knowledge_sample_question, project: project, position: 0)

      expect(described_class.for_projects([ project.id ]).ordered).to eq([ first, second ])
    end
  end
end
