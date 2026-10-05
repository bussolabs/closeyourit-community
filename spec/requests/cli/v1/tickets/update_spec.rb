# frozen_string_literal: true

require "rails_helper"

# CYRA-244: l'update via CLI (PATCH /tickets/:id) delega stato/responsabile/traguardo ai service
# dedicati, quindi produce le stesse notifiche e auto-iscrizioni del canale web (parità di canale).
# Corpo bloccato (triage claimato) → patch di soli metadati, come fa la CLI su un ticket in lavorazione.
RSpec.describe "Cli::V1::Tickets update (CYRA-244)", type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:, with_agent_workflow: true) }
  let(:member) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  before do
    create(:membership, account:, organization:, role: :owner)
    ticket.agent_workflow.update!(triage_started_at: Time.current) # corpo bloccato → patch solo meta
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def patch_ticket(params)
    patch "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", params:, headers:
  end

  it "assegnando un membro: il membro inizia a seguire il ticket e riceve la notifica" do
    expect do
      perform_enqueued_jobs(only: Ticketing::NotifyJob) { patch_ticket(assignee_id: member.id) }
    end.to change { ticket.subscriptions.where(account: member).count }.from(0).to(1)

    expect(response).to have_http_status(:ok)
    expect(ticket.reload.assignee).to eq(member)
    expect(Alerting::Notification.where(account: member, event_type: :ticket_assigned)).to exist
  end

  # CYRA-609 — questa è la SECONDA porta da cui il terminale sposta uno stato: uno `status_id` dentro
  # una modifica del ticket. Con una lavorazione in corso è chiusa come il comando dedicato, altrimenti
  # basterebbe cambiare porta per aggirare il blocco.
  it "con una lavorazione in corso il terminale non sposta lo stato, nemmeno di nascosto" do
    new_status = create(:ticket_status, organization:)
    prima = ticket.status

    expect { patch_ticket(status_id: new_status.id) }.not_to have_enqueued_job(Ticketing::NotifyJob)

    expect(response).to have_http_status(:conflict)
    expect(ticket.reload.status).to eq(prima)
  end

  it "senza una lavorazione avviata lo stato si sposta come sempre, e avvisa i watcher" do
    ticket.agent_workflow.update!(triage_started_at: nil)
    new_status = create(:ticket_status, organization:)
    # Senza il corpo bloccato vale il contratto del form completo: i campi assenti equivalgono alla
    # loro rimozione, quindi si rimandano insieme allo stato.
    completo = { status_id: new_status.id, title: ticket.title, description: ticket.description,
                 priority_id: ticket.priority_id }

    expect { patch_ticket(completo) }.to have_enqueued_job(Ticketing::NotifyJob)

    expect(response).to have_http_status(:ok), response.body
    expect(ticket.reload.status).to eq(new_status)
  end

  # CYRA-788 — il traguardo è l'ULTIMO campo applicato: se viene rifiutato, stato e assegnatario già
  # passati non devono restare salvati, e nessun avviso deve partire.
  it "traguardo rifiutato → stato e assegnatario non risultano salvati e nessun avviso parte" do
    ticket.agent_workflow.update!(triage_started_at: nil)
    new_status = create(:ticket_status, organization:)
    milestone_altrui = create(:milestone, project: create(:project, organization:))
    completo = { status_id: new_status.id, assignee_id: member.id, milestone_id: milestone_altrui.id,
                 title: ticket.title, description: ticket.description, priority_id: ticket.priority_id }

    expect { patch_ticket(completo) }.not_to have_enqueued_job(Ticketing::NotifyJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-004")
    ticket.reload
    expect(ticket.status).not_to eq(new_status)
    expect(ticket.assignee).to be_nil
    expect(ticket.milestone).to be_nil
    expect(Ticketing::Event.where(ticket: ticket)).not_to exist
  end
end
