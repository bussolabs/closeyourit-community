# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Ideas::Conversions", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:, title: "Dark mode", author: nil) }

  before { Types::InstallDefaults.call(organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def convert_path(target = idea)
    "/cli/v1/projects/#{project.id}/ideas/#{target.id}/conversion"
  end

  it "senza bearer → 401" do
    put convert_path
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "con title+description espliciti converte SENZA chiamare l'AI → 201 ticket" do
      allow(::Ideas::SynthesizeTicket).to receive(:call)

      expect do
        put convert_path, params: { title: "Dark mode dashboard", description: "Testo rivisto" }, headers: headers
      end.to change(Ticketing::Ticket, :count).by(1)

      expect(::Ideas::SynthesizeTicket).not_to have_received(:call)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["title"]).to eq("Dark mode dashboard")
      expect(idea.reload).to be_status_converted
    end

    it "senza bozza esplicita → sintesi AI inline e ticket con il testo generato" do
      draft = ::Ideas::SynthesizeTicket::Draft.new(title: "Titolo AI", description: "Descrizione AI")
      allow(::Ideas::SynthesizeTicket).to receive(:call).with(idea:).and_return(Result.ok(draft))

      put convert_path, headers: headers

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["title"]).to eq("Titolo AI")
      expect(idea.reload.ticket.description).to eq("Descrizione AI")
    end

    it "AI giù e nessuna bozza → propaga R502-AI-*, idea resta aperta" do
      allow(::Ideas::SynthesizeTicket).to receive(:call)
        .and_return(Result.err(AppError.new("gateway giù", code: "R502-AI-001", status: :bad_gateway)))

      expect { put convert_path, headers: headers }.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]["code"]).to eq("R502-AI-001")
      expect(idea.reload).to be_status_open
    end

    it "idea già convertita → 422 R422-IDEA-003 senza chiamare l'AI" do
      converted = create(:idea, :converted, organization:, project:)
      allow(::Ideas::SynthesizeTicket).to receive(:call)

      put convert_path(converted), headers: headers

      expect(::Ideas::SynthesizeTicket).not_to have_received(:call)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-003")
    end
  end

  context "member con accesso ma senza ideas.convert" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "conversione di un'idea altrui → 403" do
      expect do
        put convert_path, params: { title: "x", description: "y" }, headers: headers
      end.not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "l'AUTORE converte la propria idea anche senza permesso → 201" do
      own_idea = create(:idea, organization:, project:, author: account)

      put convert_path(own_idea), params: { title: "Mia idea", description: "Testo" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(own_idea.reload).to be_status_converted
    end
  end
end
