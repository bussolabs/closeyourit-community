# frozen_string_literal: true

require "rails_helper"

# CYRA-325 — che ne è stato di una richiesta che il link punta ma la coda non ha più.
RSpec.describe Home::Approvals::Settled, type: :service do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:visible_projects) { organization.projects }
  let(:visible_tickets) { organization.tickets }

  before { create(:membership, account:, organization:, role: :owner) }

  def call(key)
    described_class.call(account:, organization:, visible_projects:, visible_tickets:, key:)
  end

  def ticket = create(:ticket, organization:, project:)

  it "su un piano approvato dice chi e quando, col ticket" do
    subject_ticket = ticket
    workflow = create(:agent_workflow, ticket: subject_ticket, planned_at: 2.hours.ago,
                                       approved_at: 1.hour.ago, approved_by: account)

    outcome = call("agent_plan:#{workflow.id}")

    expect(outcome.documented?).to be(true)
    expect(outcome.actor_name).to eq(account.name)
    expect(outcome.at).to be_within(1.second).of(workflow.approved_at)
    expect(outcome.ticket).to eq(subject_ticket)
  end

  it "su una lavorazione annullata riporta l'annullamento, che è l'ultima decisione" do
    workflow = create(:agent_workflow, ticket:, planned_at: 3.hours.ago,
                                       cancelled_at: 1.hour.ago, cancelled_by: account)

    expect(call("agent_plan:#{workflow.id}").at).to be_within(1.second).of(workflow.cancelled_at)
  end

  # CYRA-868 — il sì automatico non ha un autore. Senza questo la pagina diceva «decisa da qualcun
  # altro», che manda a cercare una persona che non esiste.
  it "sul sì automatico dopo i controlli verdi dice che l'ha deciso il sistema" do
    workflow = create(:agent_workflow, ticket:, planned_at: 3.hours.ago, approved_at: 2.hours.ago,
                                       approved_by: account, autopilot_approved_at: 1.hour.ago)

    outcome = call("agent_plan:#{workflow.id}")

    expect(outcome.actor_name).to eq(I18n.t("member.tickets.activity.system.autopilot"))
    expect(outcome.at).to be_within(1.second).of(workflow.autopilot_approved_at)
  end

  it "su una lavorazione mai decisa dice solo che non è in coda" do
    workflow = create(:agent_workflow, ticket:, planned_at: 1.hour.ago)

    outcome = call("agent_plan:#{workflow.id}")

    expect(outcome.documented?).to be(false)
    expect(outcome.ticket).to be_present
  end

  it "su una review legge la decisione dalla cronologia del ticket" do
    subject_ticket = ticket
    Ticketing::Event.create!(organization:, ticket: subject_ticket, actor: account,
                             actor_name: "Chi Ha Deciso", action: "review_approved")

    outcome = call("review:#{subject_ticket.id}")

    expect(outcome.actor_name).to eq("Chi Ha Deciso")
    expect(outcome.documented?).to be(true)
  end

  it "un ticket che non vedo è indistinguibile da uno che non esiste" do
    altrove = create(:project, organization: create(:organization))
    foreign = create(:ticket, organization: altrove.organization, project: altrove)

    outcome = call("review:#{foreign.id}")

    expect(outcome.ticket).to be_nil
    expect(outcome.documented?).to be(false)
  end

  it "una review senza eventi in cronologia non è documentata, ma il ticket c'è" do
    outcome = call("review:#{ticket.id}")

    expect(outcome.documented?).to be(false)
    expect(outcome.ticket).to be_present
  end

  it "un chiarimento inesistente torna un esito vuoto" do
    outcome = call("clarification:#{SecureRandom.uuid}")

    expect(outcome.ticket).to be_nil
    expect(outcome.documented?).to be(false)
  end

  it "un chiarimento risposto senza commento collegato resta senza autore" do
    subject_ticket = ticket
    workflow = create(:agent_workflow, ticket: subject_ticket, planned_at: 2.hours.ago)
    clarification = create(:agent_clarification, workflow:, answered_at: 1.hour.ago)

    outcome = call("clarification:#{clarification.id}")

    expect(outcome.ticket).to eq(subject_ticket)
    expect(outcome.actor_name).to be_nil
    expect(outcome.at).to be_within(1.second).of(clarification.answered_at)
  end

  it "una richiesta segreti inesistente o di un progetto che non vedo torna un esito vuoto" do
    expect(call("secret_change:#{SecureRandom.uuid}").documented?).to be(false)

    # Decisa e con autore: se lo scope di visibilità sparisse, documented? diventerebbe true.
    altrove = create(:secret_change_request, decided_at: 1.hour.ago, decided_by: create(:account))
    expect(call("secret_change:#{altrove.id}").documented?).to be(false)
  end

  it "una richiesta segreti decisa da un account poi rimosso resta documentata senza nome" do
    request = create(:secret_change_request, project:, organization:,
                     decided_at: 1.hour.ago, decided_by: create(:account))
    # La rimozione dell'account azzera la FK: qui si riproduce lo stato risultante.
    request.update_column(:decided_by_id, nil)

    outcome = call("secret_change:#{request.id}")

    expect(outcome.actor_name).to be_nil
    expect(outcome.at).to be_within(1.second).of(request.decided_at)
  end

  it "una chiave malformata o di tipo ignoto non è un esito" do
    expect(call("non-una-chiave")).to be_nil
    expect(call("misterioso:#{SecureRandom.uuid}")).to be_nil
    expect(call("agent_plan:")).to be_nil
  end
end
