# frozen_string_literal: true

require "rails_helper"

# "Chiedi alla KB" (RAG): endpoint ASINCRONO come #compose — accoda Ai::RunJob e risponde 202 con
# request_id; l'esecuzione del service (Knowledge::AskPages, ora sul server AI) e la serializzazione
# delle citazioni sono coperte da spec/jobs/ai/run_job_spec.rb, il polling da
# spec/requests/member/ai/requests_spec.rb. Così una domanda AI lenta non tiene occupato un thread
# web per minuti (CYRA-275).
RSpec.describe "Member::Knowledge — chiedi alla KB (RAG)", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org, name: "Backend") }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login (pagina e query)" do
    get ask_member_knowledge_pages_path
    expect(response).to redirect_to(login_path)

    post ask_member_knowledge_pages_path, params: { question: "x" }
    expect(response).to redirect_to(login_path)
  end

  it "GET ask → 200 con form" do
    sign_in(member)
    get ask_member_knowledge_pages_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="knowledge-ask-input"')
  end

  describe "struttura dell'esito (CYRA-417 Scenario 3)" do
    it "l'elenco delle pagine precede la risposta generata nel DOM" do
      sign_in(member)
      get ask_member_knowledge_pages_path

      pages_idx = response.body.index('data-test="knowledge-ask-citations"')
      answer_idx = response.body.index('data-test="knowledge-ask-answer"')
      expect(pages_idx).to be_present
      expect(answer_idx).to be_present
      # Prima le pagine pertinenti, poi la risposta: si aprono le fonti, non ci si fida solo del riassunto.
      expect(pages_idx).to be < answer_idx
    end

    # CYRA-831 — gemello della pagina dei ticket: quando l'accesso a un gruppo viene tolto mentre la
    # domanda è in coda, le pagine di quel gruppo non entrano più nella risposta e la nota lo dice,
    # invece di lasciar credere che la knowledge base non avesse niente da dire.
    it "tiene pronto il posto della nota sul perimetro cambiato" do
      sign_in(member)
      get ask_member_knowledge_pages_path

      nota = Nokogiri::HTML(response.body).at_css("[data-test='knowledge-ask-scope-reduced']")
      expect(nota).to be_present
      expect(nota.text).to eq(I18n.t("member.knowledge.ask.scope_reduced"))
      # `hidden` è un attributo booleano: presente e vuoto. Nasce nascosto, lo accende il risultato.
      expect(nota.attributes).to have_key("hidden")
    end

    it "la risposta generata è un blocco separato e dichiarato dalle pagine" do
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).to include(I18n.t("member.knowledge.ask.pages_heading"))
      expect(response.body).to include(I18n.t("member.knowledge.ask.answer_heading"))
      # La risposta ha un contenitore proprio, distinto da quello delle citazioni.
      expect(response.body).to include('data-knowledge-ask-target="answerWrapper"')
    end
  end

  it "202 con request_id, crea la Ai::Request pending (kind knowledge_ask) e accoda Ai::RunJob" do
    sign_in(member)

    expect do
      post ask_member_knowledge_pages_path, params: { question: "che DB usiamo?" }, as: :json
    end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

    expect(response).to have_http_status(:accepted)
    data = response.parsed_body["data"]
    expect(data["status"]).to eq("pending")

    request_record = Ai::Request.find(data["request_id"])
    expect(request_record).to be_status_pending
    expect(request_record.kind).to eq("knowledge_ask")
    expect(request_record.account).to eq(member)
    expect(request_record.args["question"]).to eq("che DB usiamo?")
    expect(request_record.args["full_access"]).to be(false)
    expect(request_record.args["project_ids"]).to contain_exactly(project.id)
    expect(request_record.args["actor_account_id"]).to eq(member.id)
  end

  it "POST domanda vuota → 422 R422-KNOWLEDGE-003 e nessun job" do
    sign_in(member)

    expect do
      post ask_member_knowledge_pages_path, params: { question: "" }, as: :json
    end.not_to change(Ai::Request, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-003")
  end

  describe "riga di scope (CYRA-421 Scenario 2)" do
    it "dichiara su quali progetti e quante pagine risponderà" do
      create(:knowledge_page, project: project, title: "Deploy")
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-ask-scope"')
      expect(response.body).to include(I18n.t("member.knowledge.ask.scope_projects", count: 1))
      expect(response.body).to include(I18n.t("member.knowledge.ask.scope_pages", count: 1))
      expect(response.body).to include("Backend")
    end
  end

  describe "domande d'esempio (CYRA-421 Scenario 1)" do
    it "mostra i semi seminati per i progetti visibili, cliccabili" do
      create(:knowledge_sample_question, :decision, organization: org, project: project, title: "Scelta del DB")
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-ask-sample"')
      expect(response.body).to include(I18n.t("member.knowledge.ask.samples.decision", title: "Scelta del DB"))
    end

    it "in mancanza di semi ricava gli esempi dalle pagine visibili (fallback)" do
      create(:knowledge_page, :guide, project: project, title: "Runbook deploy")
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-ask-sample"')
      expect(response.body).to include(I18n.t("member.knowledge.ask.samples.guide", title: "Runbook deploy"))
    end

    it "non mostra semi di progetti che l'utente non vede" do
      other = create(:project, organization: org)
      create(:knowledge_sample_question, organization: org, project: other, title: "Roba altrui")
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).not_to include(I18n.t("member.knowledge.ask.samples.note", title: "Roba altrui"))
    end
  end

  describe "storico condiviso (CYRA-421 Scenario 3)" do
    it "mostra le ultime domande visibili con la risposta, tenendo fuori quelle di scope non visibile" do
      other_project = create(:project, organization: org)
      create(:knowledge_ask_log, organization: org, question: "Che DB usiamo?",
                                 answer: "Abbiamo scelto PostgreSQL.", project_ids: [ project.id ])
      create(:knowledge_ask_log, organization: org, question: "Dettagli riservati del progetto ignoto?",
                                 answer: "risposta segreta", project_ids: [ other_project.id ])
      create(:knowledge_ask_log, :org_wide, organization: org, question: "Panoramica di tutta l'organizzazione?")

      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).to include('data-test="knowledge-ask-history"')
      expect(response.body).to include("Che DB usiamo?")
      expect(response.body).to include("Abbiamo scelto PostgreSQL.")
      expect(response.body).not_to include("Dettagli riservati del progetto ignoto?")
      expect(response.body).not_to include("Panoramica di tutta l'organizzazione?")
    end

    it "senza domande passate non rende il blocco storico" do
      sign_in(member)
      get ask_member_knowledge_pages_path

      expect(response.body).not_to include('data-test="knowledge-ask-history"')
    end
  end
end
