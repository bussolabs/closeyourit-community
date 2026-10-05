# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Vulnerabilities::Ignore", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  # Path variato: è unico per progetto, e più esempi ne creano diversi sullo stesso.
  def finding_for(target_project, **attrs)
    manifest = create(:vulnerability_manifest, project: target_project, path: "Gemfile-#{SecureRandom.hex(4)}.lock")
    create(:vulnerability_finding, package: create(:vulnerability_package, manifest:),
                                   project: target_project, **attrs)
  end

  def ignore_path(finding) = "/cli/v1/vulnerabilities/#{finding.id}/ignore"

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    put ignore_path(finding_for(project))
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vulnerabilities.triage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "PUT → ignored, col motivo annotato" do
      finding = finding_for(project)

      put ignore_path(finding), params: { triage_note: "Non raggiungibile dal nostro codice." }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("ignored")
      expect(finding.reload).to have_attributes(
        status: "ignored", triage_note: "Non raggiungibile dal nostro codice."
      )
    end

    it "PUT senza motivo resta valido (il motivo è un di più, non un obbligo)" do
      finding = finding_for(project)
      put ignore_path(finding), headers: headers

      expect(response).to have_http_status(:ok)
      expect(finding.reload).to have_attributes(status: "ignored", triage_note: nil)
    end

    it "DELETE riapre e azzera la data di risoluzione" do
      finding = finding_for(project, status: :ignored, resolved_at: Time.current)

      delete ignore_path(finding), headers: headers

      expect(response).to have_http_status(:ok)
      expect(finding.reload).to have_attributes(status: "open", resolved_at: nil)
    end

    it "finding di un'altra organizzazione → 404 (anti-BOLA)" do
      estraneo = finding_for(create(:project))
      put ignore_path(estraneo), headers: headers

      expect(response).to have_http_status(:not_found)
      expect(estraneo.reload.status).to eq("open")
    end
  end

  context "member che vede il progetto ma senza vulnerabilities.triage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "NON può ignorare → 403 R403-CLIAUTH-002 e la riga resta aperta" do
      finding = finding_for(project)

      put ignore_path(finding), headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(finding.reload.status).to eq("open")
    end

    it "NON può riaprire → 403 e la riga resta ignorata" do
      finding = finding_for(project, status: :ignored)

      delete ignore_path(finding), headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(finding.reload.status).to eq("ignored")
    end
  end
end
