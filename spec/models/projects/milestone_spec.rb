# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Milestone, type: :model do
  describe "factory" do
    it "produce una milestone valida" do
      expect(build(:milestone)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede code, label, color" do
      expect(build(:milestone, code: nil)).not_to be_valid
      expect(build(:milestone, label: nil)).not_to be_valid
      expect(build(:milestone, color: nil)).not_to be_valid
    end

    it "code: formato slug, unico PER PROGETTO (stesso code ok su un altro progetto)" do
      expect(build(:milestone, code: "2.0")).not_to be_valid # cifra iniziale + punto
      project = create(:project)
      create(:milestone, project: project, code: "v2_0")
      expect(build(:milestone, project: project, code: "v2_0")).not_to be_valid
      other = create(:project, organization: project.organization)
      expect(build(:milestone, project: other, code: "v2_0")).to be_valid
    end

    it "normalizza code (slug) e label (strip)" do
      m = create(:milestone, code: "  My Code  ", label: "  Release 2  ")
      expect(m.code).to eq("my_code")
      expect(m.label).to eq("Release 2")
    end
  end

  describe "#organization_id" do
    it "delega al progetto (radice di tenancy)" do
      project = create(:project)
      milestone = create(:milestone, project: project)
      expect(milestone.organization_id).to eq(project.organization_id)
    end
  end

  describe ".ordered (per due_on, nulls last)" do
    it "ordina le milestone con data prima (crescente), quelle senza in fondo" do
      project = create(:project)
      q3 = create(:milestone, project: project, code: "q3", due_on: Date.new(2026, 9, 30))
      q2 = create(:milestone, project: project, code: "q2", due_on: Date.new(2026, 6, 30))
      someday = create(:milestone, project: project, code: "someday", due_on: nil)
      expect(project.milestones.ordered.to_a).to eq([ q2, q3, someday ])
    end
  end

  describe "integrità (milestone dello STESSO progetto del ticket)" do
    it "rifiuta una milestone di un ALTRO progetto (anche stessa org)" do
      org = create(:organization)
      project = create(:project, organization: org)
      other = create(:project, organization: org)
      foreign = create(:milestone, project: other)
      ticket = build(:ticket, organization: org, project: project, milestone: foreign)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:milestone]).to be_present
    end

    it "accetta una milestone dello stesso progetto; nil è valido (opzionale)" do
      project = create(:project)
      same = create(:milestone, project: project)
      expect(build(:ticket, organization: project.organization, project: project, milestone: same)).to be_valid
      expect(build(:ticket, organization: project.organization, project: project, milestone: nil)).to be_valid
    end
  end

  describe "#progress (pesato con fallback conteggio)" do
    it "% pesata; ticket senza weight conta 1; done = status categoria done" do
      org = create(:organization)
      project = create(:project, organization: org)
      milestone = create(:milestone, project: project)
      done = create(:ticket_status, organization: org, category: :done)
      todo = create(:ticket_status, organization: org, category: :open)
      create(:ticket, organization: org, project: project, milestone: milestone, status: done, weight: 9)
      create(:ticket, organization: org, project: project, milestone: milestone, status: todo, weight: 5)
      create(:ticket, organization: org, project: project, milestone: milestone, status: todo, weight: nil)

      p = milestone.progress
      expect(p).to include(done_weight: 9, total_weight: 15, percent: 60, done_count: 1, total_count: 3)
    end

    it "milestone senza ticket → 0%" do
      expect(create(:milestone).progress).to include(percent: 0, total_weight: 0, total_count: 0)
    end
  end

  describe "associazioni" do
    it "azzera milestone_id dei ticket alla cancellazione della milestone" do
      project = create(:project)
      milestone = create(:milestone, project: project)
      ticket = create(:ticket, organization: project.organization, project: project, milestone: milestone)
      expect { milestone.destroy }.to change { ticket.reload.milestone_id }.from(milestone.id).to(nil)
    end

    it "cade con il progetto (dependent: destroy)" do
      project = create(:project)
      create(:milestone, project: project)
      expect { project.destroy }.to change(Projects::Milestone, :count).by(-1)
    end
  end

  describe ".progress_for (batch, N milestone in 1 query)" do
    it "ids vuoti/nil → {} senza toccare il DB" do
      expect(described_class.progress_for([])).to eq({})
      expect(described_class.progress_for(nil)).to eq({})
    end
  end
end
