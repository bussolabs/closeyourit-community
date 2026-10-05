# frozen_string_literal: true

require "rails_helper"

# "Chiedi ai ticket" (RAG): endpoint ASINCRONO come #compose — accoda Ai::RunJob e risponde 202 con
# request_id; l'esecuzione del service (Ticketing::AskTickets, ora sul server AI) e la serializzazione
# delle citazioni sono coperte da spec/jobs/ai/run_job_spec.rb, il polling da
# spec/requests/member/ai/requests_spec.rb. Così una domanda AI lenta non tiene occupato un thread
# web per minuti (CYRA-275): la richiesta ritorna subito, il worker fa la chiamata al modello.
RSpec.describe "Member::Tickets — chiedi ai ticket (RAG)", type: :request do
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

  it "non autenticato → redirect login (pagina e query)" do
    get ask_member_tickets_path
    expect(response).to redirect_to(login_path)

    post ask_member_tickets_path, params: { question: "x" }
    expect(response).to redirect_to(login_path)
  end

  it "GET ask → 200 con form" do
    sign_in(member)
    get ask_member_tickets_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="tickets-ask-input"')
  end

  # The microphone shows only where transcription can answer: switched on and with a model to call.
  describe "dictation into the question" do
    before { sign_in(member) }

    it "offers the microphone when transcription is connected" do
      get ask_member_tickets_path

      expect(response.body).to include('data-test="dictation-mic"')
      expect(response.body).to include("ui--voice-inline")
    end

    it "hides the microphone when no transcription model is configured" do
      offline = Ai::Configuration.current.with(transcription_model: nil)
      allow(Ai::Configuration).to receive(:current).and_return(offline)

      get ask_member_tickets_path

      expect(response.body).not_to include('data-test="dictation-mic"')
    end

    it "hides the microphone when voice is switched off" do
      allow(Ai::Feature).to receive(:disabled?).and_call_original
      allow(Ai::Feature).to receive(:disabled?).with(:assistant_voice).and_return(true)

      get ask_member_tickets_path

      expect(response.body).not_to include('data-test="dictation-mic"')
    end
  end

  it "202 con request_id, crea la Ai::Request pending (kind ticket_ask) e accoda Ai::RunJob" do
    sign_in(member)

    expect do
      post ask_member_tickets_path, params: { question: "problemi col login?" }, as: :json
    end.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

    expect(response).to have_http_status(:accepted)
    data = response.parsed_body["data"]
    expect(data["status"]).to eq("pending")

    request_record = Ai::Request.find(data["request_id"])
    expect(request_record).to be_status_pending
    expect(request_record.kind).to eq("ticket_ask")
    expect(request_record.account).to eq(member)
    expect(request_record.args["question"]).to eq("problemi col login?")
    expect(request_record.args["project_ids"]).to contain_exactly(project.id)
  end

  # CYRA-812 — il perimetro viaggia col lavoro, ma prima di leggere viene ripassato dal perimetro di
  # allora: per farlo, il lavoro deve sapere CHI ha autorizzato la domanda.
  it "accoda anche chi ha autorizzato la domanda, per poter ricontrollare i suoi accessi" do
    sign_in(member)

    post ask_member_tickets_path, params: { question: "problemi col login?" }, as: :json

    request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
    expect(request_record.args["actor_account_id"]).to eq(member.id)
    expect(request_record.args["scope_listed"]).to be(true)
  end

  it "BOLA: i project_ids accodati sono SOLO quelli visibili al member (mai progetti altrui)" do
    hidden = create(:project, organization: org) # nessuna project_membership per il member
    sign_in(member)

    post ask_member_tickets_path, params: { question: "segreto?" }, as: :json

    request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
    expect(request_record.args["project_ids"]).to contain_exactly(project.id)
    expect(request_record.args["project_ids"]).not_to include(hidden.id)
  end

  it "domanda blank → 422 R422-TICKET-005 con envelope, nessun job" do
    sign_in(member)

    expect do
      post ask_member_tickets_path, params: { question: "   " }, as: :json
    end.not_to change(Ai::Request, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-005")
  end

  # CYRA-396 — la pagina era un campo bianco con un bottone: non diceva cosa sapesse fare, non dava
  # esempi e non conservava niente. Davanti al bianco si scrive una parola sola e non si torna più.
  describe "la pagina si presenta" do
    it "offre almeno tre domande già scritte, cliccabili" do
      sign_in(member)
      get ask_member_tickets_path

      esempi = Nokogiri::HTML(response.body).css("[data-test^='tickets-ask-example-']")
      expect(esempi.size).to be >= 3
      expect(esempi.first["data-question"]).to be_present
    end

    it "occupa tutta la larghezza, con l'header allineato alle altre pagine ticket" do
      sign_in(member)
      get ask_member_tickets_path

      expect(Nokogiri::HTML(response.body).css("[data-test='tickets-ask'] [class*='max-w-']")).to be_empty
    end

    it "dice cosa sa fare e cosa non sa fare" do
      sign_in(member)
      get ask_member_tickets_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='tickets-ask-capabilities']").text
      expect(riga).to eq(I18n.t("member.tickets.ask.capabilities"))
    end

    # CYRA-831 — se fra la domanda e la risposta l'accesso a un progetto viene tolto, la risposta si
    # restringe (CYRA-812) e senza una nota lo fa in silenzio: chi legge crede di guardare tutto
    # l'archivio. Il posto della nota è già in pagina, nascosto: la accende il risultato che dice di
    # essere stato ristretto, senza un secondo giro sul server.
    it "tiene pronto il posto della nota sul perimetro cambiato" do
      sign_in(member)
      get ask_member_tickets_path

      nota = Nokogiri::HTML(response.body).at_css("[data-test='tickets-ask-scope-reduced']")
      expect(nota).to be_present
      expect(nota.text).to eq(I18n.t("member.tickets.ask.scope_reduced"))
      # `hidden` è un attributo booleano: presente e vuoto. Nasce nascosto, lo accende il risultato.
      expect(nota.attributes).to have_key("hidden")
    end

    it "arrivando dalla ricerca senza risultati la frase cercata è già nel campo" do
      sign_in(member)
      get ask_member_tickets_path(q: "pagamenti che falliscono")

      campo = Nokogiri::HTML(response.body).at_css("[data-test='tickets-ask-input']").text
      expect(campo).to include("pagamenti che falliscono")
    end

    it "le domande già fatte restano consultabili" do
      Ai::Request.create!(account: member, organization: org, kind: "ticket_ask", status: :done,
                          args: { "question" => "Chi ha aperto più ticket?" })

      sign_in(member)
      get ask_member_tickets_path

      storico = Nokogiri::HTML(response.body).at_css("[data-test='tickets-ask-history']")
      expect(storico.text).to include("Chi ha aperto più ticket?")
    end
  end
end
