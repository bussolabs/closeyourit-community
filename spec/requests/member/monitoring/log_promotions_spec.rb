# frozen_string_literal: true

require "rails_helper"

# CYRA-347 — da un rallentamento si apre un ticket con un pulsante; da un messaggio no, si poteva
# solo agganciare un ticket che esisteva già. Ma il messaggio è spesso il primo posto dove si vede un
# problema nuovo: proprio lì il percorso «trovo, apro il lavoro» si interrompeva.
RSpec.describe "Member — apri un ticket da un messaggio", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:entry) do
    create(:log_entry, project:, level: :error, environment: "production", release: "v1.4.2",
                       logger_name: "Resend", message: "The associated domain with your API key is not verified")
  end

  before do
    create(:membership, account: owner, organization:, role: :owner)
    Types::InstallDefaults.call(organization:)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  it "il ticket nasce già compilato col testo, il progetto, l'ambiente e la versione" do
    sign_in(owner)

    expect { post member_monitoring_log_entry_promotion_path(entry) }.to change(Ticketing::Ticket, :count).by(1)

    ticket = Ticketing::Ticket.order(:created_at).last
    expect(ticket.project).to eq(project)
    expect(ticket.title).to include("The associated domain")
    expect(ticket.description).to include(entry.message)
    expect(ticket.technical_analysis).to include("production").and include("v1.4.2")
  end

  # Un messaggio nudo (senza ambiente, versione, origine né identificativo di richiesta) non deve
  # produrre righe con l'etichetta e niente accanto: resta solo quello che si sa davvero, cioè quando
  # è successo — che c'è sempre.
  it "un messaggio senza contesto non porta etichette vuote nel registro tecnico" do
    sign_in(owner)
    nudo = create(:log_entry, project:, level: :error, message: "Solo il messaggio",
                              environment: nil, release: nil, logger_name: nil, trace_id: nil)

    post member_monitoring_log_entry_promotion_path(nudo)

    ticket = Ticketing::Ticket.order(:created_at).last
    expect(ticket.description).to include("Solo il messaggio")
    expect(ticket.technical_analysis).to include("Occurred at:")
    expect(ticket.technical_analysis).not_to match(/Environment|Release|Logger|Trace/)
  end

  it "il messaggio resta collegato al ticket appena nato" do
    sign_in(owner)

    post member_monitoring_log_entry_promotion_path(entry)

    ticket = Ticketing::Ticket.order(:created_at).last
    expect(entry.reload.links.map(&:linkable)).to include(ticket)
  end

  it "sulla scheda si vede il ticket, e il pulsante sparisce" do
    sign_in(owner)
    post member_monitoring_log_entry_promotion_path(entry)

    get member_monitoring_log_entry_path(entry)

    expect(response.body).to include('data-test="log-ticket-link"')
    expect(response.body).not_to include('data-test="promote-ticket"')
  end

  it "finché non c'è un ticket la scheda lo dichiara e offre il pulsante" do
    sign_in(owner)

    get member_monitoring_log_entry_path(entry)

    expect(response.body).to include('data-test="log-not-promoted"')
    expect(response.body).to include('data-test="promote-ticket"')
  end

  # Il rischio dichiarato nel ticket: lo stesso messaggio si ripete decine di volte, e senza un
  # controllo ogni riga aprirebbe il suo ticket.
  it "un messaggio identico già promosso non apre un secondo ticket" do
    sign_in(owner)
    post member_monitoring_log_entry_promotion_path(entry)
    gemello = create(:log_entry, project:, level: :error, message: entry.message)

    expect { post member_monitoring_log_entry_promotion_path(gemello) }.not_to change(Ticketing::Ticket, :count)

    atteso = Ticketing::Ticket.order(:created_at).last
    expect(gemello.reload.links.map(&:linkable)).to include(atteso)
  end

  it "un messaggio diverso apre il suo ticket" do
    sign_in(owner)
    post member_monitoring_log_entry_promotion_path(entry)
    altro = create(:log_entry, project:, level: :error, message: "Tutt'altro guasto")

    expect { post member_monitoring_log_entry_promotion_path(altro) }.to change(Ticketing::Ticket, :count).by(1)
  end

  it "senza il permesso di collegare non si apre niente" do
    membro = create(:account)
    create(:membership, account: membro, organization:, role: :member)
    sign_in(membro)

    expect { post member_monitoring_log_entry_promotion_path(entry) }.not_to change(Ticketing::Ticket, :count)
  end

  # Anti-BOLA: un messaggio che non vedo non esiste.
  it "un messaggio di un'altra organizzazione dà 404" do
    sign_in(owner)
    estraneo = create(:log_entry, project: create(:project))

    post member_monitoring_log_entry_promotion_path(estraneo)

    expect(response).to have_http_status(:not_found)
  end
end
