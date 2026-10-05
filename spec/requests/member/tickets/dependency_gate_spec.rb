# frozen_string_literal: true

require "rails_helper"

# Gate hard delle dipendenze sul cambio stato via board (CYRA-81): il drag verso una colonna
# in_progress/done di un ticket con prerequisiti aperti è rifiutato server-side. Il controller risponde
# con lo status dell'errore (non un redirect che il fetch seguirebbe come 200) così il ticket-board
# ripristina la card e mostra l'alert dopo il reload.
RSpec.describe "Member::Tickets dependency gate", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:in_progress) { create(:ticket_status, :in_progress, organization: org) }

  before do
    # owner = vede tutti i progetti dell'org e può gestire (tickets.edit) → niente project_membership.
    create(:membership, account: admin, organization: org, role: :owner)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # A dipende da `count` blocker aperti (bulk nel setup → fuori dalla misura N+1 di produzione).
  def build_blocked_ticket(count: 1, blocker_status: open_status, blocker_project: project)
    ticket = create(:ticket, organization: org, project: project, status: open_status)
    allow_n_plus_one do
      count.times do
        blocker = create(:ticket, organization: org, project: blocker_project, status: blocker_status)
        create(:ticket_dependency, ticket: ticket, blocker: blocker)
      end
    end
    ticket
  end

  it "verso in_progress con un prerequisito aperto → 422, status invariato, nessun broadcast" do
    sign_in(admin)
    ticket = build_blocked_ticket

    expect do
      patch status_member_ticket_path(ticket), params: { status_id: in_progress.id }
    end.not_to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))

    expect(response).to have_http_status(:unprocessable_content)
    expect(ticket.reload.status).to eq(open_status)
  end

  it "persiste l'alert localizzato per il reload della board" do
    sign_in(admin)
    ticket = build_blocked_ticket

    patch status_member_ticket_path(ticket), params: { status_id: in_progress.id }

    expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.blocked_by_dependencies", count: 1))
  end

  it "compone l'errore su molti prerequisiti (cross-project) senza N+1 e resta 422" do
    sign_in(admin)
    ticket = build_blocked_ticket(count: 6, blocker_project: create(:project, organization: org))

    patch status_member_ticket_path(ticket), params: { status_id: in_progress.id }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "prerequisito done → la transizione riesce (200 back) e broadcasta lo spostamento" do
    sign_in(admin)
    done = create(:ticket_status, :done, organization: org)
    ticket = build_blocked_ticket(blocker_status: done)

    expect do
      patch status_member_ticket_path(ticket), params: { status_id: in_progress.id }
    end.to have_broadcasted_to(Realtime::Streams.project_board(ticket.project)).at_least(:once)

    expect(ticket.reload.status).to eq(in_progress)
  end

  # CYRA-82: il badge "bloccato" del dependent vive sulla board del SUO progetto (cross-project). Il
  # cambio stato del blocker deve rinfrescare anche quella board, non solo quella del blocker.
  it "il cambio stato del blocker rinfresca la board del progetto dei dependents (cross-project)" do
    sign_in(admin)
    done = create(:ticket_status, :done, organization: org)
    dependent_project = create(:project, organization: org)
    dependent = create(:ticket, organization: org, project: dependent_project, status: open_status)
    blocker = create(:ticket, organization: org, project: project, status: open_status)
    create(:ticket_dependency, ticket: dependent, blocker: blocker)

    expect do
      patch status_member_ticket_path(blocker), params: { status_id: done.id }
    end.to have_broadcasted_to(Realtime::Streams.project_board(dependent_project)).at_least(:once)
  end
end
