# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workload::Action, type: :model do
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }

  # CYRA-147 — attività in scadenza (per il promemoria workload_due_soon).
  describe ".due_soon" do
    let(:now) { Time.zone.local(2026, 8, 7, 12, 0, 0) }

    it "include un'attività aperta con scadenza entro la soglia" do
      action = create(:workload_action, status: :planned, due_at: now + 12.hours)
      expect(described_class.due_soon(at: now)).to include(action)
    end

    it "include un'attività aperta già scaduta" do
      action = create(:workload_action, status: :in_progress, due_at: now - 2.days)
      expect(described_class.due_soon(at: now)).to include(action)
    end

    it "esclude un'attività con scadenza oltre la soglia" do
      action = create(:workload_action, status: :planned, due_at: now + 3.days)
      expect(described_class.due_soon(at: now)).not_to include(action)
    end

    it "esclude le attività chiuse anche se scadute" do
      done = create(:workload_action, :done, due_at: now - 1.day)
      cancelled = create(:workload_action, status: :cancelled, due_at: now - 1.day)
      expect(described_class.due_soon(at: now)).not_to include(done, cancelled)
    end

    it "esclude un'attività senza scadenza" do
      action = create(:workload_action, status: :planned, due_at: nil)
      expect(described_class.due_soon(at: now)).not_to include(action)
    end
  end

  describe "validazioni" do
    it "è valida con team e titolo" do
      expect(build(:workload_action, team: team)).to be_valid
    end

    it "rifiuta il titolo mancante (anche solo spazi, via normalizes)" do
      action = build(:workload_action, team: team, title: "   ")
      expect(action).not_to be_valid
      expect(action.errors[:title]).to be_present
    end

    it "accetta ticket e created_by assenti" do
      expect(build(:workload_action, team: team, ticket: nil, created_by: nil)).to be_valid
    end
  end

  describe "normalizzazioni" do
    it "rimuove gli spazi da titolo e descrizione" do
      action = build(:workload_action, team: team, title: "  Fiera Milano  ", description: "  note  ")
      expect(action.title).to eq("Fiera Milano")
      expect(action.description).to eq("note")
    end
  end

  describe "enum status" do
    it "definisce gli stati con prefisso" do
      expect(described_class.statuses).to eq("planned" => 0, "in_progress" => 1, "done" => 2, "cancelled" => 3)
    end

    it "espone i predicati con prefisso" do
      expect(build(:workload_action, status: :done)).to be_status_done
    end
  end

  describe "attr_readonly :team_id" do
    it "vieta il cambio di team dopo la creazione" do
      action = create(:workload_action, organization: organization, team: team)
      other_team = create(:team, organization: organization)

      expect { action.update(team_id: other_team.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(action.reload.team_id).to eq(team.id)
    end
  end

  describe "#ticket_same_organization" do
    it "accetta un ticket nella stessa organizzazione del team" do
      ticket = create(:ticket, organization: organization, project: create(:project, organization: organization))

      expect(build(:workload_action, team: team, ticket: ticket)).to be_valid
    end

    it "rifiuta un ticket di un'altra organizzazione" do
      other_org = create(:organization)
      ticket = create(:ticket, organization: other_org, project: create(:project, organization: other_org))

      action = build(:workload_action, team: team, ticket: ticket)

      expect(action).not_to be_valid
      expect(action.errors[:ticket]).to be_present
    end

    it "nullifica il link quando il ticket viene cancellato" do
      action = create(:workload_action, :with_ticket, organization: organization)

      action.ticket.destroy

      expect(action.reload.ticket_id).to be_nil
    end
  end

  describe "#organization_id" do
    it "delega al team (radice di tenancy, non al progetto)" do
      action = create(:workload_action, team: team, organization: organization)
      expect(action.organization_id).to eq(organization.id)
    end
  end

  describe ".visible_to" do
    let(:team_b) { create(:team, organization: organization) }
    let(:account) { create(:account) }

    before { create(:team_membership, team: team, account: account) }

    it "include le actions dei team a cui appartiene l'account" do
      action = create(:workload_action, team: team, organization: organization)

      expect(described_class.visible_to(account: account, organization: organization)).to include(action)
    end

    it "esclude le actions di un team a cui l'account non appartiene" do
      other = create(:workload_action, team: team_b, organization: organization)

      expect(described_class.visible_to(account: account, organization: organization)).not_to include(other)
    end

    it "esclude le actions di un'altra organizzazione anche se l'account vi appartiene" do
      cross_org = create(:organization)
      cross_team = create(:team, organization: cross_org)
      create(:team_membership, team: cross_team, account: account)
      cross_action = create(:workload_action, team: cross_team, organization: cross_org)

      expect(described_class.visible_to(account: account, organization: organization)).not_to include(cross_action)
    end
  end

  describe "factory" do
    it "il trait :done è valido e completato" do
      action = create(:workload_action, :done)
      expect(action).to be_status_done
      expect(action.completed_at).to be_present
    end

    it "il trait :with_participants crea partecipanti membri del team" do
      action = create(:workload_action, :with_participants)

      expect(action.participants.count).to eq(2)
      action.participants.each do |account|
        expect(Connections::TeamMembership.exists?(account_id: account.id, team_id: action.team_id)).to be(true)
      end
    end
  end

  describe "scopes" do
    it ".by_status filtra per stato" do
      planned = create(:workload_action, status: :planned)
      done = create(:workload_action, status: :done)

      result = described_class.by_status(:planned)
      expect(result).to include(planned)
      expect(result).not_to include(done)
    end

    it ".ordered mette le pianificate più recenti prima e le senza data in coda" do
      early = create(:workload_action, scheduled_at: 2.days.ago)
      late = create(:workload_action, scheduled_at: 1.hour.ago)
      undated = create(:workload_action, scheduled_at: nil)

      ordered = described_class.where(id: [ early, late, undated ]).ordered.to_a

      expect(ordered.index(late)).to be < ordered.index(early)
      expect(ordered.last).to eq(undated)
    end
  end
end
