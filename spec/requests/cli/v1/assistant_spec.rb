# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Assistant", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }

  before do
    create(:membership, account:, organization:, role: :owner)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def other_account_headers
    other = create(:account)
    other_org = create(:organization)
    create(:membership, account: other, organization: other_org, role: :owner)
    other_secret = Accounts::ApiTokens::Issue.call(account: other, organization: other_org, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{other_secret}" }
  end

  it "senza token → 401" do
    get "/cli/v1/assistant/conversations"

    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST /cli/v1/assistant/conversations" do
    it "apre una conversazione vuota" do
      post "/cli/v1/assistant/conversations", headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("id")
    end
  end

  describe "GET /cli/v1/assistant/conversations" do
    it "elenca le conversazioni dell'account con la paginazione" do
      Assistant::Conversation.create!(account:, organization:, kind: :tools, title: "una")

      get "/cli/v1/assistant/conversations", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].pluck("title")).to eq([ "una" ])
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "non mostra quelle di un altro account" do
      Assistant::Conversation.create!(account:, organization:, kind: :tools, title: "mia")

      get "/cli/v1/assistant/conversations", headers: other_account_headers

      expect(response.parsed_body["data"]).to be_empty
    end
  end

  describe "GET /cli/v1/assistant/conversations/:id" do
    it "restituisce la conversazione con i suoi messaggi in ordine" do
      conversation = Assistant::Conversation.create!(account:, organization:, kind: :tools)
      conversation.messages.create!(organization:, role: :user, status: :complete, content: "prima")
      conversation.messages.create!(organization:, role: :assistant, status: :complete, content: "seconda")

      get "/cli/v1/assistant/conversations/#{conversation.id}", headers: headers

      expect(response.parsed_body["data"]["messages"].pluck("content")).to eq(%w[prima seconda])
    end

    it "non lascia leggere quella di un altro" do
      conversation = Assistant::Conversation.create!(account:, organization:, kind: :tools)

      get "/cli/v1/assistant/conversations/#{conversation.id}", headers: other_account_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /cli/v1/assistant/conversations/:id" do
    it "cancella la propria conversazione" do
      conversation = Assistant::Conversation.create!(account:, organization:, kind: :tools)

      delete "/cli/v1/assistant/conversations/#{conversation.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Assistant::Conversation.exists?(conversation.id)).to be(false)
    end
  end

  describe "POST /cli/v1/assistant/conversations/:id/messages" do
    let(:conversation) { Assistant::Conversation.create!(account:, organization:, kind: :tools) }

    it "risponde 202 con la risposta in lavorazione e accoda il lavoro" do
      project # esiste, così il perimetro non è vuoto

      expect {
        post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
             params: { text: "che progetti ho?" }, headers: headers
      }.to have_enqueued_job(Assistant::ConverseJob)

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["data"]).to include("status" => "streaming", "role" => "assistant")
      expect(conversation.messages.role_user.last.content).to eq("che progetti ho?")
    end

    # Il perimetro va congelato all'invio: ricalcolarlo nel job darebbe quello di un altro momento.
    it "consegna al lavoro il perimetro visibile in questo istante e la domanda a cui rispondere" do
      project

      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "ciao" }, headers: headers

      expect(Assistant::ConverseJob).to have_been_enqueued.with(
        hash_including(project_ids: [ project.id ],
                       question_id: conversation.messages.role_user.last.id,
                       full_access: true)
      )
    end

    it "dà un titolo alla conversazione a partire dalla prima domanda" do
      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "come sta CYRA?" }, headers: headers

      expect(conversation.reload.title).to eq("come sta CYRA?")
    end

    # Il titolo è la PRIMA domanda: riscriverlo a ogni invio farebbe cambiare nome alla conversazione
    # sotto gli occhi di chi la sta cercando nell'elenco.
    it "non riscrive il titolo già dato" do
      conversation.update!(title: "il primo titolo")

      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "un'altra domanda" }, headers: headers

      expect(conversation.reload.title).to eq("il primo titolo")
    end

    it "rifiuta una domanda vuota senza accodare nulla" do
      expect {
        post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
             params: { text: "   " }, headers: headers
      }.not_to have_enqueued_job(Assistant::ConverseJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-ASSISTANT-001")
    end

    it "non fa scrivere in una conversazione di un altro" do
      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "ciao" }, headers: other_account_headers

      expect(response).to have_http_status(:not_found)
    end

    # Con l'assistente spento la domanda non deve essere accolta: una risposta accettata e mai
    # scritta è peggio di un rifiuto immediato. Stessa scelta di Assistant::PostMessage sul web.
    it "rifiuta se l'assistente con attrezzi è spento" do
      allow(Ai::Feature).to receive(:disabled?).with(:assistant_tools).and_return(true)

      expect {
        post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
             params: { text: "che progetti ho?" }, headers: headers
      }.not_to have_enqueued_job(Assistant::ConverseJob)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("error", "code")).to eq(Ai::Feature::ERROR_CODE)
      expect(conversation.messages).to be_empty
    end
  end

  describe "i tetti sulla domanda" do
    let(:conversation) { Assistant::Conversation.create!(account:, organization:, kind: :tools) }

    # Sul web il testo abbondante viene troncato in silenzio; qui no: chi manda una domanda tagliata
    # a metà riceverebbe la risposta a una domanda che non ha fatto, senza sapere che è successo.
    it "rifiuta una domanda più lunga del consentito, senza accodare nulla" do
      expect {
        post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
             params: { text: "a" * (Assistant::Constants::MAX_MESSAGE_CHARS + 1) }, headers: headers
      }.not_to have_enqueued_job(Assistant::ConverseJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-ASSISTANT-004")
      expect(conversation.messages).to be_empty
    end

    it "accetta una domanda lunga quanto il consentito" do
      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "a" * Assistant::Constants::MAX_MESSAGE_CHARS }, headers: headers

      expect(response).to have_http_status(:accepted)
    end
  end

  # I due assistenti condividono la tabella ma hanno regole opposte: quello del sito indica le
  # pagine e non parla dei dati, questo li legge. Mescolarli significa dare a uno la storia
  # dell'altro, e lasciare che un canale cancelli i thread dell'altro.
  describe "le conversazioni dei due assistenti restano separate" do
    it "apre le conversazioni come conversazioni con attrezzi" do
      post "/cli/v1/assistant/conversations", headers: headers

      expect(Assistant::Conversation.find(response.parsed_body["data"]["id"])).to be_kind_tools
    end

    it "non elenca quelle nate nel sito" do
      Assistant::Conversation.create!(account:, organization:, kind: :help, title: "dal sito")
      Assistant::Conversation.create!(account:, organization:, kind: :tools, title: "dall'app")

      get "/cli/v1/assistant/conversations", headers: headers

      expect(response.parsed_body["data"].pluck("title")).to eq([ "dall'app" ])
    end

    it "non lascia cancellare una conversazione nata nel sito" do
      web = Assistant::Conversation.create!(account:, organization:, kind: :help)

      delete "/cli/v1/assistant/conversations/#{web.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(web.reload).to be_persisted
    end

    it "non lascia scrivere in una conversazione nata nel sito" do
      web = Assistant::Conversation.create!(account:, organization:, kind: :help)

      post "/cli/v1/assistant/conversations/#{web.id}/messages", params: { text: "ciao" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(web.messages).to be_empty
    end
  end

  describe "GET /cli/v1/assistant/messages/:id" do
    let(:conversation) { Assistant::Conversation.create!(account:, organization:, kind: :tools) }
    let(:message) do
      conversation.messages.create!(organization:, role: :assistant, status: :complete,
                                    content: "Hai 3 ticket da fare.", tools_used: %w[list_projects])
    end

    it "restituisce contenuto, stato e attrezzi usati" do
      get "/cli/v1/assistant/messages/#{message.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "status" => "complete", "content" => "Hai 3 ticket da fare.", "tools_used" => [ "list_projects" ]
      )
    end

    it "restituisce il motivo quando la risposta è fallita" do
      failed = conversation.messages.create!(organization:, role: :assistant, status: :failed,
                                             error_code: "R502-LLM-001")

      get "/cli/v1/assistant/messages/#{failed.id}", headers: headers

      expect(response.parsed_body["data"]).to include("status" => "failed", "error_code" => "R502-LLM-001")
    end

    it "non lascia leggere la risposta di un altro" do
      get "/cli/v1/assistant/messages/#{message.id}", headers: other_account_headers

      expect(response).to have_http_status(:not_found)
    end

    # La proprietà vive sulla conversazione: una risposta nata nel sito non si legge dall'app.
    it "non lascia leggere un messaggio nato nel sito" do
      web = Assistant::Conversation.create!(account:, organization:, kind: :help)
      web_message = web.messages.create!(organization:, role: :assistant, status: :complete, content: "dal sito")

      get "/cli/v1/assistant/messages/#{web_message.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  # L'AI la offre il sistema (CYRA-765): non c'è più un servizio da collegare per organizzazione,
  # quindi la domanda viene accolta anche senza credenziali di integrazione.
  describe "senza credenziali di integrazione" do
    let(:conversation) { Assistant::Conversation.create!(account:, organization:, kind: :tools) }

    it "accoglie la domanda con 202 e mette il lavoro in coda" do
      expect do
        post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
             params: { text: "quanti ticket aperti?" }, headers: headers
      end.to change { conversation.messages.count }.by(2)
      expect(Assistant::ConverseJob).to have_been_enqueued

      expect(response).to have_http_status(:accepted)
    end
  end
end
