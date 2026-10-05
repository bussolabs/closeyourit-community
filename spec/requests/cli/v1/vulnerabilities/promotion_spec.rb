# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Vulnerabilities::Promotion", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  # I default status/priority del ticket servono perché PromoteToTicket → CreateTicket li risolve.
  before { Types::InstallDefaults.call(organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  # Path variato: è unico per progetto, e più esempi ne creano diversi sullo stesso.
  def finding_for(target_project, **attrs)
    manifest = create(:vulnerability_manifest, project: target_project, path: "Gemfile-#{SecureRandom.hex(4)}.lock")
    create(:vulnerability_finding, package: create(:vulnerability_package, manifest:),
                                   project: target_project, **attrs)
  end

  def promotion_path(finding) = "/cli/v1/vulnerabilities/#{finding.id}/promotion"

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    put promotion_path(finding_for(project))
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vulnerabilities.triage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "promuove → 201 col ticket creato, finding.promoted?" do
      finding = finding_for(project)

      expect do
        put promotion_path(finding), headers: headers
      end.to change(Ticketing::Ticket, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("id", "code")
      expect(response.parsed_body["data"]["id"]).to eq(finding.reload.ticket_id)
      expect(finding).to be_promoted
    end

    # La promozione automatica scatta solo su high/critical: a mano si apre un ticket su qualsiasi
    # riga, perché chi guarda sa se quella moderate lo riguarda.
    it "promuove anche una severity che non promuove da sola" do
      manifest = create(:vulnerability_manifest, project:)
      finding = create(:vulnerability_finding, package: create(:vulnerability_package, manifest:),
                                               advisory: create(:vulnerability_advisory, :low), project:)

      put promotion_path(finding), headers: headers

      expect(response).to have_http_status(:created)
      expect(finding.reload).to be_promoted
    end

    it "già promossa → 422 R422-VULN-001, nessun secondo ticket" do
      finding = finding_for(project)
      put promotion_path(finding), headers: headers
      expect(response).to have_http_status(:created)

      expect do
        put promotion_path(finding), headers: headers
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-VULN-001")
    end

    it "finding di un'altra organizzazione → 404 (anti-BOLA)" do
      estraneo = finding_for(create(:project))

      expect do
        put promotion_path(estraneo), headers: headers
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza vulnerabilities.triage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "NON può promuovere → 403 R403-CLIAUTH-002, nessun ticket" do
      finding = finding_for(project)

      expect do
        put promotion_path(finding), headers: headers
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(finding.reload).not_to be_promoted
    end
  end
end
