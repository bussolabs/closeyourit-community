# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Vulnerabilities::Ignore", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:next_month) { 1.month.from_now.to_date }

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

    it "PUT con motivo e scadenza → ignored, e la risposta riporta scadenza e autore" do
      finding = finding_for(project)

      put ignore_path(finding), params: { reason: "Solo sviluppo.", ignored_until: next_month.iso8601 },
                                headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("status" => "ignored", "triage_note" => "Solo sviluppo.",
                              "ignored_until" => next_month.iso8601)
      expect(data["ignored_by"]).to eq("id" => account.id, "name" => account.name)
      expect(finding.reload).to have_attributes(
        status: "ignored", triage_note: "Solo sviluppo.", ignored_until: next_month, ignored_by_id: account.id
      )
    end

    it "PUT senza motivo → 422 e la riga resta aperta" do
      finding = finding_for(project)

      put ignore_path(finding), params: { reason: "", ignored_until: next_month.iso8601 }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-VULNERABILITY-001")
      expect(response.parsed_body["error"]["details"]).to have_key("triage_note")
      expect(finding.reload).to have_attributes(status: "open", ignored_until: nil, ignored_by_id: nil)
    end

    it "PUT con la data di oggi → 422 e la riga resta aperta" do
      finding = finding_for(project)

      put ignore_path(finding), params: { reason: "Solo sviluppo.", ignored_until: Date.current.iso8601 },
                                headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["details"]).to have_key("ignored_until")
      expect(finding.reload.status).to eq("open")
    end

    # Il comando di prima mandava al più la nota facoltativa: niente eccezioni, ma un messaggio che
    # dice la mossa giusta — aggiornare il programma.
    [ {}, { triage_note: "Non raggiungibile dal nostro codice." } ].each do |old_params|
      it "rejects legacy CLI parameters #{old_params.inspect} and asks to update" do
        finding = finding_for(project)

        put ignore_path(finding), params: old_params, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]["code"]).to eq("R422-VULNERABILITY-002")
        expect(response.parsed_body["error"]["message"]).to include("update the CLI")
        expect(finding.reload.status).to eq("open")
      end
    end

    it "DELETE riapre e svuota scadenza, autore e data di risoluzione" do
      finding = finding_for(project, status: :ignored, triage_note: "Solo sviluppo.", resolved_at: Time.current,
                                     ignored_until: next_month, ignored_by: account)

      delete ignore_path(finding), headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("ignored_until" => nil, "ignored_by" => nil)
      expect(finding.reload).to have_attributes(status: "open", resolved_at: nil, ignored_until: nil,
                                                ignored_by_id: nil)
    end

    it "finding di un'altra organizzazione → 404 (anti-BOLA)" do
      estraneo = finding_for(create(:project))
      put ignore_path(estraneo), params: { reason: "x", ignored_until: next_month.iso8601 }, headers: headers

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

      put ignore_path(finding), params: { reason: "Solo sviluppo.", ignored_until: next_month.iso8601 },
                                headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(finding.reload).to have_attributes(status: "open", ignored_by_id: nil)
    end

    it "NON può riaprire → 403 e la riga resta ignorata" do
      finding = finding_for(project, status: :ignored)

      delete ignore_path(finding), headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(finding.reload.status).to eq("ignored")
    end
  end
end
