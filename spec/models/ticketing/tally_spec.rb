# frozen_string_literal: true

require "rails_helper"

# CYRA-358: la definizione UNICA di "Da fare / In corso / Concluso / Non chiusi". Conta per
# CATEGORIA di status, non per code: così in_review rientra in "In corso" e closed in "Concluso",
# e la somma dei tre quadra sempre col totale (prima open/in_progress/resolved-per-code lasciavano
# fuori in_review e closed → i chip non tornavano e "aperti" valeva insiemi diversi).
RSpec.describe Ticketing::Tally do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  let(:todo)        { create(:ticket_status, organization: org, code: "open", category: :open) }
  let(:in_progress) { create(:ticket_status, organization: org, code: "in_progress", category: :in_progress) }
  let(:in_review)   { create(:ticket_status, organization: org, code: "in_review", category: :in_progress) }
  let(:resolved)    { create(:ticket_status, organization: org, code: "resolved", category: :done) }
  let(:closed)      { create(:ticket_status, organization: org, code: "closed", category: :done) }

  def ticket(status)
    create(:ticket, organization: org, project: project, status: status)
  end

  describe ".for" do
    it "raggruppa i conteggi per categoria di status" do
      2.times { ticket(todo) }
      ticket(in_progress)
      ticket(in_review)
      3.times { ticket(resolved) }
      ticket(closed)

      counts = described_class.for(project.tickets)

      expect(counts.todo).to eq(2)
      expect(counts.done).to eq(4)      # resolved (3) + closed (1)
      expect(counts.total).to eq(8)
    end

    it "conta 'In corso' come in lavorazione + in revisione (categoria in_progress)" do
      ticket(in_progress)
      ticket(in_review)

      expect(described_class.for(project.tickets).in_progress).to eq(2)
    end

    it "'Non chiusi' è la somma di Da fare e In corso, mai i conclusi" do
      2.times { ticket(todo) }
      ticket(in_progress)
      ticket(in_review)
      ticket(resolved)
      ticket(closed)

      counts = described_class.for(project.tickets)

      expect(counts.unresolved).to eq(4) # todo (2) + in_progress (1) + in_review (1)
    end

    it "todo + in_progress + done quadra sempre col totale" do
      ticket(todo)
      ticket(in_review)
      ticket(closed)

      counts = described_class.for(project.tickets)

      expect(counts.todo + counts.in_progress + counts.done).to eq(counts.total)
      expect(counts.total).to eq(3)
    end

    it "restituisce zero su un insieme vuoto" do
      counts = described_class.for(project.tickets)

      expect([ counts.todo, counts.in_progress, counts.done, counts.unresolved, counts.total ]).to all(eq(0))
    end
  end

  describe ".by_project" do
    it "produce i conteggi per progetto in un solo colpo" do
      other = create(:project, organization: org)
      ticket(todo)
      ticket(in_progress)
      create(:ticket, organization: org, project: other, status: closed)

      by_project = described_class.by_project(Ticketing::Ticket.where(project_id: [ project.id, other.id ]))

      expect(by_project[project.id].todo).to eq(1)
      expect(by_project[project.id].in_progress).to eq(1)
      expect(by_project[project.id].unresolved).to eq(2)
      expect(by_project[other.id].done).to eq(1)
      expect(by_project[other.id].unresolved).to eq(0)
    end

    it "omette i progetti senza ticket (il chiamante usa Tally.empty)" do
      by_project = described_class.by_project(Ticketing::Ticket.where(project_id: project.id))

      expect(by_project).to be_empty
      expect(described_class.empty.unresolved).to eq(0)
    end
  end
end
