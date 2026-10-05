# frozen_string_literal: true

require "rails_helper"

# Copre il rendering della show con tutte le varianti: chip ruolo reporter/assignee/altro,
# allegato immagine inline su commento, allegato non-immagine sul ticket (file chip).
RSpec.describe "Member ticket show — discussion & attachments rendering", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before { create(:membership, account: admin, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "rende commenti (reporter/assignee/altro), allegato immagine e non-immagine" do
    ticket.update!(assignee: admin)

    create(:ticket_comment, ticket: ticket, author: ticket.reporter) # role reporter
    image_comment = create(:ticket_comment, ticket: ticket, author: admin) # role assignee
    image_comment.files.attach(fixture_file_upload("screenshot.png", "image/png"))

    third = create(:account)
    create(:membership, account: third, organization: org, role: :member)
    create(:project_membership, account: third, project: project)
    file_comment = create(:ticket_comment, ticket: ticket, author: third) # role nil
    file_comment.files.attach(fixture_file_upload("notes.txt", "text/plain")) # allegato non-immagine su commento

    ticket.files.attach(fixture_file_upload("notes.txt", "text/plain"))

    sign_in(admin)

    # CYRA-219: commenti e allegati vivono in due schede diverse — la discussione e il dettaglio.
    get member_ticket_path(ticket, tab: "discussion")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="member-ticket-comments"')
    expect(response.body).to include("notes.txt")

    get member_ticket_path(ticket)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="member-ticket-attachments"')
    expect(response.body).to include("notes.txt")
  end

  # CYRA-385 — commento ed evento di un automatismo (service account) si distinguono da una persona:
  # badge robot + etichetta "Automazione" sul commento, frase impersonale + badge col nome sull'evento.
  it "distingue nel rendering commento ed evento prodotti da un automatismo" do
    admin.update!(locale: "it")
    agent = create(:account, :service, name: "server-minion-1")
    create(:membership, account: agent, organization: org, role: :member)

    comment = create(:ticket_comment, ticket: ticket, author: agent)
    event = create(:ticket_event, ticket: ticket, actor: agent, actor_name: agent.name,
                                   action: "status_changed",
                                   data: { "status" => { "from" => "In Progress", "to" => "In Review" } })

    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response).to have_http_status(:ok)
    # Commento: avatar-badge automatico (forma/colore diversi) + etichetta, niente chip di ruolo umano.
    expect(response.body).to include(%(data-test="member-ticket-comment-automation-#{comment.id}"))
    expect(response.body).to include("Automazione")
    expect(response.body).to include("server-minion-1")
    # Evento: descritto come automazione, non attribuito a una persona (apostrofo HTML-escaped nel
    # body → assero la porzione distintiva; il wording esatto è coperto dallo unit del presenter).
    expect(response.body).to include("ha portato il ticket in In Review")
    expect(response.body).not_to include("server-minion-1 ha cambiato lo stato")
    expect(response.body).to include(%(data-test="member-ticket-event-automation-#{event.id}"))
  end

  # La dropzone allegati deve esporre il wiring Stimulus per il feedback + auto-upload.
  # (Il comportamento JS — requestSubmit, stato "Caricamento…", drag&drop — non è
  # eseguibile sotto rack_test: qui si asserisce solo il cablaggio DOM.)
  it "espone il wiring Stimulus della dropzone allegati" do
    sign_in(admin)
    get member_ticket_path(ticket)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-controller="attachment-upload"')
    expect(response.body).to include('data-attachment-upload-target="input"')
    expect(response.body).to include('data-attachment-upload-target="status"')
  end

  # Contratto realtime read-side: la show DEVE sottoscriversi allo stream del ticket ed esporre i
  # target id stabili su cui i broadcast (write-side) fanno append/replace/remove.
  it "espone il contratto realtime: subscription al ticket + target id stabili" do
    ticket.update!(assignee: admin)
    comment = create(:ticket_comment, ticket: ticket, author: admin)

    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response).to have_http_status(:ok)
    # turbo_stream_from Realtime::Streams.ticket(@ticket) → custom element di sottoscrizione cable.
    expect(response.body).to include("turbo-cable-stream-source")
    # target id stabili (devono combaciare coi target dei broadcast).
    expect(response.body).to include(%(id="ticket_timeline_#{ticket.id}"))
    expect(response.body).to include(%(id="ticket_comments_count_#{ticket.id}"))
    expect(response.body).to include(%(id="ticketing_ticket_#{ticket.id}_status"))
    expect(response.body).to include(%(id="ticketing_ticket_#{ticket.id}_assignee"))
    expect(response.body).to include(%(id="ticketing_ticket_#{ticket.id}_watchers"))
    # la bolla-commento ha il suo dom_id stabile (append de-dup / remove).
    expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(comment)}"))
  end
end
