# frozen_string_literal: true

require "rails_helper"

# AI Buddy: endpoint ASINCRONO come #analyze — accoda Ai::RunJob e risponde 202 con request_id;
# l'esecuzione del service (Ticketing::ComposeTicket) è coperta da spec/services/ e dal dispatch
# in spec/jobs/ai/run_job_spec.rb, il polling da spec/requests/member/ai/requests_spec.rb.
# A differenza di #analyze NON c'è flag di progetto: basta un progetto visibile + testo non vuoto.
RSpec.describe "Member::Tickets#compose", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login" do
    post compose_member_tickets_path, params: { project_id: project.id, text: "x" }
    expect(response).to redirect_to(login_path)
  end

  context "membro autenticato, progetto visibile" do
    before do
      sign_in(member)
    end

    it "202 con request_id, crea la Ai::Request pending e accoda Ai::RunJob (kind ticket_compose)" do
      expect do
        post compose_member_tickets_path, params: { project_id: project.id, text: "il login va in timeout su mobile" }
      end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      data = response.parsed_body["data"]
      expect(data["status"]).to eq("pending")

      request_record = Ai::Request.find(data["request_id"])
      expect(request_record).to be_status_pending
      expect(request_record.kind).to eq("ticket_compose")
      expect(request_record.account).to eq(member)
      expect(request_record.args).to eq({ "project_id" => project.id, "text" => "il login va in timeout su mobile" })
    end

    # CYRA-632 — il secondo giro. La bozza da correggere NON viaggia sul filo: il client manda l'id
    # della richiesta che l'ha prodotta, e il payload lo rileggiamo noi.
    describe "correzione della bozza" do
      let(:payload) { { "title" => "Timeout al login", "kind" => "bug", "description" => "Va in timeout." } }
      let(:previous) do
        create(:ai_request, account: member, organization: org, kind: "ticket_compose",
                            status: :done, payload: payload)
      end

      def correct(overrides = {})
        post compose_member_tickets_path,
             params: { project_id: project.id, text: "il login va in timeout su mobile",
                       correction: "è una story, non un bug", previous_request_id: previous.id }.merge(overrides)
      end

      it "porta correzione e bozza precedente negli args" do
        correct

        expect(response).to have_http_status(:accepted)
        args = Ai::Request.find(response.parsed_body.dig("data", "request_id")).args
        expect(args).to include("correction" => "è una story, non un bug", "previous_draft" => payload)
      end

      # Anti-BOLA: la richiesta di un altro account non è leggibile nemmeno di rimbalzo, passando per
      # il prompt di una bozza. Stesso scoping di Member::Ai::RequestsController.
      it "404 se la richiesta precedente è di un altro account" do
        other = create(:ai_request, account: create(:account), organization: org, kind: "ticket_compose",
                                    status: :done, payload: payload)
        previous # la fixture nasce prima del blocco, o il conteggio misura lei invece dell'endpoint

        expect { correct(previous_request_id: other.id) }.not_to change(Ai::Request, :count)
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body.dig("error", "code")).to eq("R404-AI-001")
      end

      # Le richieste sono effimere (Ai::PruneRequestsJob): chi corregge una bozza vecchia va avvisato,
      # non servito con una bozza scritta da zero che sembra la sua corretta male.
      it "404 se la richiesta precedente è scaduta" do
        previous

        expect { correct(previous_request_id: SecureRandom.uuid) }.not_to change(Ai::Request, :count)
        expect(response).to have_http_status(:not_found)
      end

      # Il payload di un triage errori non ha nulla da fare dentro il prompt che scrive un ticket.
      it "404 se la richiesta precedente è di un altro tipo" do
        triage = create(:ai_request, account: member, organization: org, kind: "error_triage",
                                     status: :done, payload: payload)

        correct(previous_request_id: triage.id)
        expect(response).to have_http_status(:not_found)
      end

      # Una correzione senza bozza non è una correzione: si compone da capo, come ha sempre fatto.
      it "compone da capo se la correzione è vuota" do
        correct(correction: "  ")

        expect(response).to have_http_status(:accepted)
        args = Ai::Request.find(response.parsed_body.dig("data", "request_id")).args
        expect(args.keys).to contain_exactly("project_id", "text")
      end
    end

    it "testo vuoto → 422 R422-TICKET-012 e nessun job" do
      expect do
        post compose_member_tickets_path, params: { project_id: project.id, text: "   " }
      end.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-012")
    end

    it "progetto non visibile (BOLA) → 404 R404-TICKET-002 e nessun job" do
      other = create(:project, organization: org) # nessuna project_membership per member

      expect do
        post compose_member_tickets_path, params: { project_id: other.id, text: "x" }
      end.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-TICKET-002")
    end
  end
end
