# frozen_string_literal: true

require "rails_helper"

# Timeline unificata (commenti + eventi di sistema) sulla show del ticket: rendering,
# fusione cronologica, visibilità per ruolo, snapshot delle label, badge impersonation.
RSpec.describe "Member ticket activity timeline", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before { create(:membership, account: admin, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "rende un evento di sistema nella timeline (id + valori, locale-indipendente)" do
    event = create(:ticket_event, ticket: ticket, action: "status_changed",
                   data: { "status" => { "from" => "Open", "to" => "Closed" } })
    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(data-test="member-ticket-event-#{event.id}"))
    expect(response.body).to include("Open").and include("Closed")
  end

  it "fonde commenti ed eventi in ordine cronologico crescente" do
    create(:ticket_comment, ticket: ticket, author: ticket.reporter,
           body: "primo-commento", created_at: 2.hours.ago)
    event = create(:ticket_event, ticket: ticket, action: "status_changed",
                   data: { "status" => { "from" => "A", "to" => "B" } }, created_at: 1.hour.ago)
    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    body = response.body
    expect(body.index("primo-commento")).to be < body.index("member-ticket-event-#{event.id}")
  end

  it "il customer con accesso al progetto vede la timeline" do
    customer = create(:account)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:project_membership, account: customer, project: project)
    event = create(:ticket_event, ticket: ticket)

    sign_in(customer)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("member-ticket-event-#{event.id}")
  end

  it "il customer SENZA accesso al progetto → 404 (anti-BOLA, niente timeline)" do
    customer = create(:account)
    create(:membership, account: customer, organization: org, role: :customer)

    sign_in(customer)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response).to have_http_status(:not_found)
  end

  it "mostra la label STORICA anche dopo la rinomina dello stato (snapshot, non join live)" do
    status = create(:ticket_status, organization: org, label: "In revisione")
    create(:ticket_event, ticket: ticket, action: "status_changed",
           data: { "status" => { "from" => "Aperto", "to" => "In revisione" } })
    status.update!(label: "QA") # rinomina DOPO l'evento

    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response.body).to include("In revisione")
  end

  it "mostra il badge impersonation quando true_actor differisce da actor" do
    god = create(:account)
    create(:ticket_event, ticket: ticket, action: "created", actor: ticket.reporter, true_actor: god)

    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    expect(response.body).to include(I18n.t("member.tickets.activity.impersonated"))
  end

  it "a parità di created_at la timeline è ordinata in modo deterministico (tie-break su id)" do
    instant = 1.hour.ago
    comment = create(:ticket_comment, ticket: ticket, author: ticket.reporter,
                     body: "commento-tie", created_at: instant)
    event = create(:ticket_event, ticket: ticket, action: "status_changed",
                   data: { "status" => { "from" => "A", "to" => "B" } }, created_at: instant)

    sign_in(admin)
    get member_ticket_path(ticket, tab: "discussion")

    body = response.body
    pos_comment = body.index("commento-tie")
    pos_event = body.index("member-ticket-event-#{event.id}")
    # Ordine atteso = tie-break su item.id (il sort del controller usa [created_at, item.id]).
    if comment.id < event.id
      expect(pos_comment).to be < pos_event
    else
      expect(pos_event).to be < pos_comment
    end
  end
end
