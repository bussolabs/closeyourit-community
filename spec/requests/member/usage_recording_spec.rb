# frozen_string_literal: true

require "rails_helper"

# CYRA-700 — il lato che parla: aprire una pagina dell'area autenticata registra la funzionalità.
RSpec.describe "Member usage recording", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Usage::SelfRecorder.reset!
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  after { Usage::SelfRecorder.reset! }

  it "aprire un elenco registra la funzionalità corrispondente" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_tickets_path

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered.keys).to include([ "route", "Member::TicketsController#index" ])
  end

  # CYRA-733 — la stessa apertura vale due volte: la rotta per l'inventario del codice, la funzione
  # per la domanda di prodotto («questa serve ancora?»).
  it "aprire un elenco registra anche la funzione di prodotto, con la chiave stabile" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_tickets_path

    expect(Usage::SelfRecorder.buffered.keys).to include([ "feature_view", "tickets" ])
  end

  it "una pagina dentro la funzione porta la chiave della funzione, non una sua" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_project_documents_path(project)

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered.keys).to include([ "feature_view", "projects" ])
  end

  it "una pagina fuori dal catalogo resta registrata come rotta, senza funzione" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_datasets_path

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered.keys).to include([ "route", "Member::DatasetsController#index" ])
    expect(Usage::SelfRecorder.buffered.keys.map(&:first)).not_to include("feature_view")
  end

  it "un redirect non conta come funzione aperta" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_ticket_path("non-esiste-proprio")

    expect(Usage::SelfRecorder.buffered).to be_empty
  end

  it "senza progetto configurato non registra niente" do
    get member_tickets_path

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered).to be_empty
  end

  # CYRA-733 — le due metà legate: si apre una pagina, e la funzione compare nella pagina d'uso del
  # progetto. Separate, le due prove non dicono che il giro si chiude davvero.
  it "una pagina aperta si ritrova nella pagina d'uso del progetto, col nome della funzione" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_tickets_path
    Usage::SelfRecorder.flush_if_due!(now: Time.current + Usage::SelfRecorder::WINDOW + 1.second)
    argomenti = ActiveJob::Base.queue_adapter.enqueued_jobs.last.fetch("arguments").first
    Usage::IngestJob.new.perform(**argomenti.except("_aj_ruby2_keywords").symbolize_keys)

    get member_project_usage_path(project)

    expect(response).to have_http_status(:ok)
    righe = Nokogiri::HTML(response.body).css("[data-test='usage-row']").text
    expect(righe).to include(I18n.t("member.assistant.catalog.tickets.label"))
  end

  # CYRA-733 — Turbo scarica in anticipo la pagina di un link al passaggio del mouse: senza questo
  # confine bastava sfiorare le voci del menu per far risultare «usate» funzioni che nessuno ha
  # aperto, ed è proprio quel conteggio che decide cosa vale la pena tenere.
  it "una pagina scaricata in anticipo dal browser non conta come aperta" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_tickets_path, headers: { "X-Sec-Purpose" => "prefetch" }

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered).to be_empty
  end

  it "vale anche per l'anticipo chiesto dal browser, non solo da Turbo" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)

    get member_tickets_path, headers: { "Sec-Purpose" => "prefetch;prerender" }

    expect(Usage::SelfRecorder.buffered).to be_empty
  end

  # CYRA-823 — la scheda di un agente ricarica da sola il suo riquadro dell'attività a ogni battito
  # della macchina: sono richieste della pagina, non aperture di una persona.
  it "un pezzo di pagina che si ricarica da solo non conta come apertura" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)
    host = create(:agent_host, organization: org)

    get member_agent_path(host), headers: { "Turbo-Frame" => "host-activity" }

    expect(response).to have_http_status(:ok)
    expect(Usage::SelfRecorder.buffered).to be_empty
  end

  it "la stessa pagina aperta per intero invece conta" do
    allow(Usage::SelfRecorder).to receive(:project_id).and_return(project.id)
    host = create(:agent_host, organization: org)

    get member_agent_path(host)

    expect(Usage::SelfRecorder.buffered.keys).to include([ "route", "Member::AgentsController#show" ])
  end

  it "un guasto del registratore non fa fallire la pagina" do
    allow(Usage::SelfRecorder).to receive(:record).and_raise(StandardError, "coda irraggiungibile")

    get member_tickets_path

    expect(response).to have_http_status(:ok)
  end
end
