# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Ticket, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  describe "tipi di ticket" do
    it "apre story, task ed epic su un progetto qualunque: nessun flag li governa" do
      %i[story task epic].each do |trait|
        expect(build(:ticket, trait, organization: org, project: project)).to be_valid
      end
    end
  end

  describe "epic come contenitore" do
    let(:epic) { create(:ticket, :epic, organization: org, project: project) }

    it "una story sotto un epic dello stesso progetto è valida" do
      expect(build(:ticket, :story, organization: org, project: project, parent: epic)).to be_valid
    end

    it "compare tra i figli dell'epic" do
      child = create(:ticket, :story, organization: org, project: project, parent: epic)
      expect(epic.reload.children).to contain_exactly(child)
    end

    it "rifiuta un padre che non è un epic" do
      story = create(:ticket, :story, organization: org, project: project)
      ticket = build(:ticket, :task, organization: org, project: project, parent: story)
      expect(ticket).to be_invalid
      expect(ticket.errors[:parent]).to be_present
    end

    it "rifiuta un epic di un ALTRO progetto (anti-leak, come la milestone)" do
      other_epic = create(:ticket, :epic, organization: org, project: create(:project, organization: org))
      ticket = build(:ticket, :story, organization: org, project: project, parent: other_epic)
      expect(ticket).to be_invalid
      expect(ticket.errors[:parent]).to be_present
    end

    it "rifiuta un epic annidato sotto un altro epic: la gerarchia è di un livello solo" do
      nested = build(:ticket, :epic, organization: org, project: project, parent: epic)
      expect(nested).to be_invalid
      expect(nested.errors[:parent]).to be_present
    end

    it "rifiuta un ticket padre di sé stesso" do
      ticket = create(:ticket, :story, organization: org, project: project)
      ticket.parent_id = ticket.id
      expect(ticket).to be_invalid
      expect(ticket.errors[:parent]).to be_present
    end

    it "impedisce a un epic con figli di cambiare tipo" do
      create(:ticket, :story, organization: org, project: project, parent: epic)
      epic.kind = :story
      expect(epic).to be_invalid
      expect(epic.errors[:kind]).to be_present
    end

    it "lascia cambiare tipo a un epic senza figli" do
      epic.kind = :story
      expect(epic).to be_valid
    end

    it "alla cancellazione dell'epic i figli sopravvivono senza padre" do
      child = create(:ticket, :story, organization: org, project: project, parent: epic)
      epic.destroy!
      expect(child.reload.parent_id).to be_nil
    end
  end
end
