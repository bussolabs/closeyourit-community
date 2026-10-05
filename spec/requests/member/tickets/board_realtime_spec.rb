# frozen_string_literal: true

require "rails_helper"

# Board realtime: write-side (PATCH status → page-refresh sulla board del progetto del ticket) e
# read-side (la board si sottoscrive a uno stream per progetto visibile e rende i dom-id del drag).
RSpec.describe "Member::Tickets board realtime", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:done_status) { create(:ticket_status, organization: org, code: "done", label: "Done") }

  before do
    # owner = vede tutti i progetti dell'org e può gestire (tickets.edit) → niente project_membership.
    create(:membership, account: admin, organization: org, role: :owner)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def subscribed_streams(body)
    body.scan(/signed-stream-name="([^"]+)"/).flatten
        .filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
  end

  # Scritto sul COMPORTAMENTO osservabile — a quali stream la board si iscrive e quali di quelli
  # ricevono traffico — non sui nomi-stream dell'implementazione: resta valido comunque evolva
  # Realtime::Streams, ed è il test che il bug avrebbe dovuto far fallire.
  describe "isolamento per progetto (CYRA-257)" do
    let(:hidden_project) { create(:project, organization: org) }
    let(:scoped_member) { create(:account) }

    before do
      # Membro scoped sul SOLO `project`: hidden_project resta fuori da Authorization::VisibleScope.
      create(:membership, account: scoped_member, organization: org, role: :member)
      create(:project_membership, account: scoped_member, project: project)
    end

    it "nessuno stream della sua board porta i movimenti di un progetto che non vede" do
      sign_in(scoped_member)
      get member_tickets_path
      victim_streams = subscribed_streams(response.body)
      expect(victim_streams).not_to be_empty, "la board non si sottoscrive a nulla: test cieco"

      hidden_ticket = create(:ticket, organization: org, project: hidden_project, status: open_status)
      sign_in(admin)
      patch status_member_ticket_path(hidden_ticket), params: { status_id: done_status.id }

      leaked = victim_streams.select { |stream| ActionCable.server.pubsub.broadcasts(stream).any? }
      expect(leaked).to be_empty, "stream che consegnano movimenti di progetti non visibili: #{leaked.inspect}"
    end

    it "nessun broadcast di board trasporta il contenuto della card" do
      hidden_ticket = create(:ticket, organization: org, project: hidden_project,
                                      status: open_status, title: "Segreto di un altro cliente")
      sign_in(admin)
      get member_tickets_path
      board_streams = subscribed_streams(response.body)

      patch status_member_ticket_path(hidden_ticket), params: { status_id: done_status.id }

      payload = board_streams.flat_map { |stream| ActionCable.server.pubsub.broadcasts(stream) }.join
      expect(payload).not_to include(hidden_ticket.title)
      expect(payload).not_to include(%(id="board_count_))
    end

    it "chi il progetto lo vede riceve comunque l'aggiornamento" do
      sign_in(scoped_member)
      get member_tickets_path
      victim_streams = subscribed_streams(response.body)

      visible_ticket = create(:ticket, organization: org, project: project, status: open_status)
      sign_in(admin)
      patch status_member_ticket_path(visible_ticket), params: { status_id: done_status.id }

      expect(victim_streams.any? { |stream| ActionCable.server.pubsub.broadcasts(stream).any? })
        .to be(true), "il membro scoped non riceve gli spostamenti del progetto che vede"
    end
  end

  describe "GET board — contratto dom-id e sottoscrizioni (read-side)" do
    # Gli id board_column_/board_count_ non sono più target di broadcast (il service manda solo un
    # refresh), ma restano il contratto del drag ottimistico di ticket_board_controller.js.
    it "rende colonna, conteggio e card con gli id usati dal drag ottimistico" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)
      get member_tickets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="board_column_#{open_status.id}"))
      expect(response.body).to include(%(id="board_count_#{open_status.id}"))
      expect(response.body).to include(%(id="ticketing_ticket_#{ticket.id}"))
      # La card vive dentro il container della sua colonna.
      expect(response.body).to match(
        %r{id="board_column_#{open_status.id}".*id="ticketing_ticket_#{ticket.id}"}m
      )
    end

    it "si sottoscrive a uno stream per ogni progetto visibile" do
      project # `let` lazy: va istanziato PRIMA della GET, o la board non lo vede
      other = create(:project, organization: org)
      sign_in(admin)
      get member_tickets_path

      # admin è owner → vede tutti i progetti dell'org, quindi li trova entrambi.
      expect(subscribed_streams(response.body))
        .to include(Realtime::Streams.project_board(project), Realtime::Streams.project_board(other))
    end

    it "opta per il page-refresh Turbo morph (è la GET a ri-scopare la board per chi guarda)" do
      sign_in(admin)
      get member_tickets_path

      expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
    end
  end

  describe "PATCH status — broadcast (write-side)" do
    it "cambiando colonna manda un refresh sullo stream del progetto del ticket" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch status_member_ticket_path(ticket), params: { status_id: done_status.id }
      end.to have_broadcasted_to(Realtime::Streams.project_board(project)).exactly(:once)

      expect(ticket.reload.status).to eq(done_status)
    end

    it "aggiorna anche il badge stato sullo stream del ticket" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch status_member_ticket_path(ticket), params: { status_id: done_status.id }
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket)).at_least(:once)
    end

    it "no-op (stesso status) → nessun broadcast" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch status_member_ticket_path(ticket), params: { status_id: open_status.id }
      end.not_to have_broadcasted_to(Realtime::Streams.project_board(project))
    end
  end

  # CYRA-244: gli stessi cambi fatti dal MODULO DI MODIFICA (PATCH update, non i pulsanti rapidi)
  # delegano ai service dedicati, quindi muovono la board e aggiornano il badge come il drag.
  describe "PATCH update (modulo di modifica) — broadcast (write-side)" do
    it "cambiando stato dal form manda un refresh sullo stream del progetto del ticket" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch member_ticket_path(ticket),
              params: { status_id: done_status.id, title: ticket.title, priority_id: ticket.priority_id }
      end.to have_broadcasted_to(Realtime::Streams.project_board(project)).exactly(:once)

      expect(ticket.reload.status).to eq(done_status)
    end

    it "aggiorna anche il badge stato sullo stream del ticket" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch member_ticket_path(ticket),
              params: { status_id: done_status.id, title: ticket.title, priority_id: ticket.priority_id }
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket)).at_least(:once)
    end

    it "salvando dal form senza cambiare stato non muove la board" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: open_status)

      expect do
        patch member_ticket_path(ticket),
              params: { status_id: open_status.id, title: "Titolo nuovo", priority_id: ticket.priority_id }
      end.not_to have_broadcasted_to(Realtime::Streams.project_board(project))

      expect(ticket.reload.title).to eq("Titolo nuovo")
    end
  end
end
