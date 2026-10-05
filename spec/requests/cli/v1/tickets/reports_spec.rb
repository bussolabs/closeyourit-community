# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Reports", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  def token_for(acc, org = organization)
    Accounts::ApiTokens::Issue.call(account: acc, organization: org, name: "CLI").value[:secret]
  end

  def base_path(target = ticket, scope = project)
    "/cli/v1/projects/#{scope.id}/tickets/#{target.id}"
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    post "#{base_path}/report", params: { body: "Fatto." }

    expect(response).to have_http_status(:unauthorized)
  end

  context "membro che vede il progetto (baseline: scrive il resoconto)" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    def post_report(body)
      post "#{base_path}/report", headers: headers, params: { body: body }
    end

    describe "POST report" do
      it "crea la versione 1 → 201 col resoconto serializzato" do
        expect { post_report("Fatto: coperti i rami mancanti.") }.to change(Ticketing::Report, :count).by(1)

        expect(response).to have_http_status(:created)
        data = response.parsed_body["data"]
        expect(data["version"]).to eq(1)
        expect(data["body"]).to eq("Fatto: coperti i rami mancanti.")
        expect(data["author"]).to eq(account.name)
        expect(data["source"]).to eq("agent")
        expect(data["ticket_id"]).to eq(ticket.id)
      end

      it "un secondo resoconto diverso crea la versione 2" do
        post_report("Prima stesura.")
        post_report("Seconda stesura.")

        expect(response.parsed_body["data"]["version"]).to eq(2)
        expect(ticket.reports.count).to eq(2)
      end

      it "ripostare lo stesso testo non crea una versione nuova" do
        post_report("Stesso testo.")

        expect { post_report("Stesso testo.") }.not_to change(Ticketing::Report, :count)
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["data"]["version"]).to eq(1)
      end

      it "body vuoto → 422 R422-REPORT-001 coi dettagli per campo" do
        post_report("   ")

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]["code"]).to eq("R422-REPORT-001")
        expect(response.parsed_body["error"]["details"]["body"]).to be_present
      end

      it "body oltre il tetto → 422" do
        post_report("x" * (Ticketing::Constants::REPORT_MAX_CHARS + 1))

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]["code"]).to eq("R422-REPORT-001")
      end

      it "lascia in discussione una riga di servizio breve" do
        expect { post_report("Fatto.") }.to change(ticket.comments, :count).by(1)

        comment = ticket.comments.reload.last
        expect(comment).to be_kind_service
        expect(comment.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
      end
    end

    describe "GET report" do
      it "ritorna la versione corrente" do
        post_report("Prima.")
        post_report("Seconda.")

        get "#{base_path}/report", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["data"]["version"]).to eq(2)
        expect(response.parsed_body["data"]["body"]).to eq("Seconda.")
      end

      it "ticket senza resoconto → 404 R404-REPORT-001" do
        get "#{base_path}/report", headers: headers

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["error"]["code"]).to eq("R404-REPORT-001")
      end
    end

    describe "GET report/versions" do
      it "elenca le versioni dalla più recente" do
        post_report("Prima.")
        post_report("Seconda.")

        get "#{base_path}/report/versions", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["data"].map { |v| v["version"] }).to eq([ 2, 1 ])
      end

      it "risolve una versione per numero, non per uuid" do
        post_report("Prima.")
        post_report("Seconda.")

        get "#{base_path}/report/versions/1", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["data"]["body"]).to eq("Prima.")
      end

      it "numero inesistente → 404" do
        get "#{base_path}/report/versions/9", headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "isolamento tenant (anti-BOLA)" do
    it "un membro che non vede il progetto → 404, mai 403" do
      create(:membership, account:, organization:, role: :member)

      get "#{base_path}/report", headers: { "Authorization" => "Bearer #{token_for(account)}" }

      expect(response).to have_http_status(:not_found)
    end

    it "un ticket di un'altra organizzazione → 404, mai 403" do
      create(:membership, account:, organization:, role: :owner)
      other_org = create(:organization)
      other_project = create(:project, organization: other_org)
      other_ticket = create(:ticket, project: other_project, organization: other_org)

      post "#{base_path(other_ticket, other_project)}/report",
           headers: { "Authorization" => "Bearer #{token_for(account)}" }, params: { body: "Fatto." }

      expect(response).to have_http_status(:not_found)
    end
  end
end
