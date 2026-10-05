# frozen_string_literal: true

require "rails_helper"

# L'endpoint è ASINCRONO: accoda Ai::RunJob e risponde 202 con request_id; l'esecuzione del
# service (e i suoi esiti/errori) è coperta da spec/jobs/ai/run_job_spec.rb, il polling
# dell'esito da spec/requests/member/ai/requests_spec.rb.
RSpec.describe "Member::Tickets#analyze", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org, quick_bug_report_enabled: true) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login" do
    post analyze_member_tickets_path, params: { project_id: project.id, quick_text: "x" }
    expect(response).to redirect_to(login_path)
  end

  context "membro autenticato, progetto con flag attivo" do
    before do
      sign_in(member)
    end

    it "202 con request_id, crea la Ai::Request pending e accoda Ai::RunJob" do
      expect do
        post analyze_member_tickets_path, params: { project_id: project.id, quick_text: "il checkout non parte" }
      end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      data = response.parsed_body["data"]
      expect(data["status"]).to eq("pending")

      request_record = Ai::Request.find(data["request_id"])
      expect(request_record).to be_status_pending
      expect(request_record.kind).to eq("ticket_analyze")
      expect(request_record.account).to eq(member)
      expect(request_record.args).to eq({ "project_id" => project.id, "text" => "il checkout non parte" })
    end
  end

  context "gating (invariato: i guard girano PRIMA dell'enqueue)" do
    before { sign_in(member) }

    it "flag disattivo → 422 R422-TICKET-002 e nessun job" do
      project.update!(quick_bug_report_enabled: false)

      expect do
        post analyze_member_tickets_path, params: { project_id: project.id, quick_text: "x" }
      end.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-002")
    end

    it "progetto non visibile (BOLA) → 404 R404-TICKET-002 e nessun job" do
      other = create(:project, organization: org, quick_bug_report_enabled: true) # nessuna project_membership per member

      expect do
        post analyze_member_tickets_path, params: { project_id: other.id, quick_text: "x" }
      end.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-TICKET-002")
    end

    # CYRA-765 — l'AI la offre il sistema: non c'è più nessun servizio da collegare, quindi la
    # richiesta nasce e viene accodata anche senza nessuna credenziale dell'organizzazione.
    it "senza nessuna integrazione collegata la richiesta nasce lo stesso" do
      Integrations::Credential.where(organization: org).delete_all

      expect do
        post analyze_member_tickets_path, params: { project_id: project.id, quick_text: "x" }
      end.to change(Ai::Request, :count).by(1)

      expect(response).to have_http_status(:accepted)
      expect(Ai::RunJob).to have_been_enqueued
    end
  end
end
