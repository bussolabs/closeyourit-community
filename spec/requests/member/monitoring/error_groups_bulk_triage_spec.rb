# frozen_string_literal: true

require "rails_helper"

# CYRA-45: triage bulk degli errori dalla lista (resolve/ignore/reopen su N gruppi in un colpo).
RSpec.describe "Member::Monitoring::ErrorGroups bulk triage", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST bulk_triage" do
    it "non autenticato → redirect login" do
      post bulk_triage_member_monitoring_error_groups_path, params: { ids: [], bulk_action: "resolve" }
      expect(response).to redirect_to(login_path)
    end

    context "owner (può fare triage su tutto)" do
      before { sign_in(owner) }

      it "resolve → tutti i gruppi selezionati diventano resolved, redirect con notice" do
        a = create(:error_group, project:, status: :unresolved)
        b = create(:error_group, project:, status: :unresolved)

        post bulk_triage_member_monitoring_error_groups_path,
             params: { ids: [ a.id, b.id ], bulk_action: "resolve" }

        expect(response).to redirect_to(member_monitoring_error_groups_path)
        expect(flash[:notice]).to be_present
        expect(a.reload).to be_status_resolved
        expect(b.reload).to be_status_resolved
      end

      it "ignore → i gruppi selezionati diventano ignored" do
        a = create(:error_group, project:, status: :unresolved)
        post bulk_triage_member_monitoring_error_groups_path, params: { ids: [ a.id ], bulk_action: "ignore" }
        expect(a.reload).to be_status_ignored
      end

      it "reopen → i gruppi risolti tornano unresolved" do
        a = create(:error_group, project:, status: :resolved)
        post bulk_triage_member_monitoring_error_groups_path, params: { ids: [ a.id ], bulk_action: "reopen" }
        expect(a.reload).to be_status_unresolved
      end

      it "anti-BOLA: un gruppo di un'altra org viene scartato (resta invariato)" do
        mine = create(:error_group, project:, status: :unresolved)
        other = create(:error_group, status: :unresolved) # altra org → fuori da visible.error_groups

        post bulk_triage_member_monitoring_error_groups_path,
             params: { ids: [ mine.id, other.id ], bulk_action: "resolve" }

        expect(mine.reload).to be_status_resolved
        expect(other.reload).to be_status_unresolved
      end

      it "azione non valida → alert, nulla cambia" do
        a = create(:error_group, project:, status: :unresolved)
        post bulk_triage_member_monitoring_error_groups_path, params: { ids: [ a.id ], bulk_action: "bogus" }
        expect(flash[:alert]).to be_present
        expect(a.reload).to be_status_unresolved
      end
    end

    context "member assegnato ma senza errors.triage" do
      before do
        create(:project_membership, account: member, project: project)
        sign_in(member)
      end

      it "il gruppo NON viene toccato (permesso mancante), resta unresolved" do
        a = create(:error_group, project:, status: :unresolved)
        post bulk_triage_member_monitoring_error_groups_path, params: { ids: [ a.id ], bulk_action: "resolve" }
        expect(response).to redirect_to(member_monitoring_error_groups_path)
        expect(a.reload).to be_status_unresolved
      end
    end
  end
end
