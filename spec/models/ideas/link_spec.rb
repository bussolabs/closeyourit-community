# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::Link, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:base) { create(:idea, organization: org, project: project) }
  let(:other) { create(:idea, organization: org, project: project) }

  describe "validazioni" do
    it "collega due idee dello stesso progetto" do
      expect(build(:idea_link, source: other, target: base)).to be_valid
    end

    it "rifiuta un'idea collegata a sé stessa" do
      link = build(:idea_link, source: base, target: base)
      expect(link).not_to be_valid
      expect(link.errors[:target]).to be_present
    end

    it "rifiuta idee di progetti diversi (tenancy)" do
      foreign = create(:idea, organization: org)
      link = build(:idea_link, source: foreign, target: base)
      expect(link).not_to be_valid
      expect(link.errors[:target]).to be_present
    end

    it "rifiuta una seconda relazione fra la stessa coppia, anche nel verso opposto" do
      create(:idea_link, source: other, target: base)
      expect(build(:idea_link, source: base, target: other)).not_to be_valid
      expect(build(:idea_link, :evolution, source: other, target: base)).not_to be_valid
    end
  end

  describe "evoluzioni a un solo livello" do
    it "una figlia non può avere figlie" do
      child = other
      create(:idea_link, :evolution, source: child, target: base)
      grandchild = create(:idea, organization: org, project: project)
      link = build(:idea_link, :evolution, source: grandchild, target: child)
      expect(link).not_to be_valid
      expect(link.errors[:target]).to be_present
    end

    it "una base con figlie non può diventare figlia" do
      create(:idea_link, :evolution, source: other, target: base)
      another = create(:idea, organization: org, project: project)
      link = build(:idea_link, :evolution, source: base, target: another)
      expect(link).not_to be_valid
      expect(link.errors[:source]).to be_present
    end

    it "una figlia ha un solo padre" do
      create(:idea_link, :evolution, source: other, target: base)
      another = create(:idea, organization: org, project: project)
      link = build(:idea_link, :evolution, source: other, target: another)
      expect(link).not_to be_valid
      expect(link.errors[:source]).to be_present
    end
  end

  describe "associazioni sull'idea" do
    it "espone parent, evolutions e related_ideas nei due versi" do
      create(:idea_link, :evolution, source: other, target: base)
      cousin = create(:idea, organization: org, project: project)
      create(:idea_link, source: cousin, target: base)

      expect(other.reload.parent).to eq(base)
      expect(other).to be_evolution
      expect(base.reload.evolutions).to eq([ other ])
      expect(base).not_to be_evolution
      expect(base.related_ideas).to eq([ cousin ])
      expect(cousin.reload.related_ideas).to eq([ base ])
    end

    it "cancellare un'idea cancella i suoi collegamenti" do
      create(:idea_link, :evolution, source: other, target: base)
      expect { base.destroy }.to change(Ideas::Link, :count).by(-1)
      expect(other.reload.parent).to be_nil
    end
  end
end
