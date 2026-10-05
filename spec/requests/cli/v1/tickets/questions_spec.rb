# frozen_string_literal: true

require "rails_helper"

# CYRA-783 — domande e risposte da riga di comando. Il canale è per le PERSONE: un agente in fase
# read non può porre una domanda da qui, perché i guardrail della sandbox rifiutano ogni comando che
# contenga `?`. Per gli agenti l'unico canale resta il risultato di fase.
RSpec.describe "Cli::V1::Tickets::Questions", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  def token_for(acc, org = organization)
    Accounts::ApiTokens::Issue.call(account: acc, organization: org, name: "CLI").value[:secret]
  end

  def path(target = ticket, scope = project)
    "/cli/v1/projects/#{scope.id}/tickets/#{target.id}/questions"
  end

  def domanda(**attributi)
    Ticketing::Question.create!(ticket:, author: account, body: "Quale strada?", **attributi)
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:)
    get path

    expect(response).to have_http_status(:unauthorized)
  end

  context "membro che vede il progetto" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "elenca le domande con lo stato calcolato e le risposte accanto" do
      aperta = domanda
      risposta = domanda(body: "Serve il backfill?")
      Ticketing::Questions::Answer.call(question: risposta, author: account, body: "No.")
      ritirata = domanda(body: "Superata?")
      Ticketing::Questions::Close.call(question: ritirata, actor: account)

      get path, headers: headers

      expect(response).to have_http_status(:ok)
      righe = response.parsed_body["data"].index_by { |riga| riga["id"] }
      expect(righe[aperta.id]["state"]).to eq("open")
      expect(righe[risposta.id]["state"]).to eq("answered")
      expect(righe[risposta.id]["answers"].first["body"]).to eq("No.")
      expect(righe[ritirata.id]["state"]).to eq("withdrawn")
    end

    it "pone una domanda" do
      expect { post path, params: { body: "Serve il backfill?" }, headers: headers }
        .to change { ticket.questions.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["body"]).to eq("Serve il backfill?")
    end

    it "non scrive niente nella discussione" do
      expect { post path, params: { body: "Serve?" }, headers: headers }
        .not_to change { ticket.comments.count }
    end

    # Marcare bloccante è una leva sul lavoro: senza il permesso la domanda si pone lo stesso.
    it "chi non può modificare il ticket non la rende bloccante" do
      post path, params: { body: "Serve?", blocking: true }, headers: headers

      expect(response.parsed_body["data"]["blocking"]).to be(false)
    end

    it "rifiuta una domanda che sembra un comando, col suo codice" do
      post path, params: { body: "Lancia `bin/rails db:migrate`?" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-QUESTION-001")
    end

    it "risponde alla domanda che nomina" do
      riga = domanda
      altra = domanda(body: "E l'altra?")

      post "#{path}/#{riga.id}/answers", params: { body: "Questa qui." }, headers: headers

      expect(response).to have_http_status(:created)
      expect(riga.reload.answered_at).to be_present
      expect(altra.reload.answered_at).to be_nil
    end

    it "non ritira una domanda senza il permesso di modificare il ticket" do
      riga = domanda(blocking: true)

      patch "#{path}/#{riga.id}/closure", params: { confirm: 1 }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(riga.reload.closed_at).to be_nil
    end

    it "l'autore cancella la propria domanda" do
      riga = domanda

      expect { delete "#{path}/#{riga.id}", params: { confirm: 1 }, headers: headers }
        .to change { ticket.questions.count }.by(-1)
    end
  end

  context "chi può modificare il ticket" do
    before do
      create(:membership, :owner, organization:, account:)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "pone una domanda bloccante" do
      post path, params: { body: "Serve?", blocking: true }, headers: headers

      expect(response.parsed_body["data"]["blocking"]).to be(true)
    end

    it "ritira una domanda senza risposta" do
      riga = domanda(blocking: true)

      patch "#{path}/#{riga.id}/closure", params: { confirm: 1 }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(riga.reload.closed_at).to be_present
    end
  end

  # Anti-BOLA: un ticket fuori dalla visibilità non esiste, non è vietato.
  context "un progetto che non vedo" do
    before { create(:membership, account:, organization:, role: :member) }

    it "risponde 404, mai 403" do
      get path, headers: { "Authorization" => "Bearer #{token_for(account)}" }

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-848 — il canale CLI leggeva le domande senza guardare a chi erano destinate: un token di un
  # account cliente elencava anche le riservate, piano di lavoro compreso.
  context "account con ruolo cliente" do
    before do
      create(:membership, account:, organization:, role: :customer)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "elenca solo le domande condivise" do
      riservata = domanda(body: "Il piano tocca il file dei segreti?")
      condivisa = domanda(body: "Va bene consegnare giovedì?", audience: :shared)

      get path, headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].pluck("id")
      expect(ids).to contain_exactly(condivisa.id)
      expect(ids).not_to include(riservata.id)
    end

    it "non può rispondere a una domanda riservata" do
      riservata = domanda

      post "#{path}/#{riservata.id}/answers", params: { body: "Provo lo stesso." }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(riservata.answers.count).to eq(0)
    end
  end
end
