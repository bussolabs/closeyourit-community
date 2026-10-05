# frozen_string_literal: true

require "rails_helper"

# Gli endpoint AI sono ASINCRONI: accodano Ai::RunJob e rispondono 202 con request_id
# (esecuzione: spec/jobs/ai/run_job_spec.rb; polling: spec/requests/member/ai/requests_spec.rb).
# Qui restano i guard (auth, permessi, BOLA) e il contratto dell'enqueue.
RSpec.describe "Member::Monitoring::ErrorGroups triage AI", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
    # Il triage assistito gira con la chiave dell'organizzazione (CYRA-548).
    create(:integration_credential, organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST triage_ai" do
    it "non autenticato → redirect login" do
      post triage_ai_member_monitoring_error_group_path(group)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 202 con request_id e Ai::RunJob accodato (kind error_triage)" do
      sign_in(owner)

      expect do
        post triage_ai_member_monitoring_error_group_path(group)
      end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
      expect(request_record.kind).to eq("error_triage")
      expect(request_record.args).to eq({ "group_id" => group.id })
      expect(request_record.account).to eq(owner)
    end

    it "member senza permesso errors.triage → forbidden (redirect), nessun job" do
      sign_in(member)
      create(:project_membership, account: member, project: project)

      expect do
        post triage_ai_member_monitoring_error_group_path(group)
      end.not_to change(Ai::Request, :count)

      expect(response).to redirect_to(root_path)
    end

    it "gruppo non visibile (BOLA) → 404, nessun job" do
      sign_in(owner)
      foreign = create(:error_group, project: create(:project, organization: create(:organization)))

      expect do
        post triage_ai_member_monitoring_error_group_path(foreign)
      end.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST similar" do
    it "owner → 202 con request_id e Ai::RunJob accodato (kind error_similar)" do
      sign_in(owner)

      expect do
        post similar_member_monitoring_error_group_path(group)
      end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
      expect(request_record.kind).to eq("error_similar")
      expect(request_record.args).to eq({ "group_id" => group.id })
    end

    it "member senza permesso → forbidden (redirect), nessun job" do
      sign_in(member)
      create(:project_membership, account: member, project: project)

      expect do
        post similar_member_monitoring_error_group_path(group)
      end.not_to change(Ai::Request, :count)

      expect(response).to redirect_to(root_path)
    end
  end
end
