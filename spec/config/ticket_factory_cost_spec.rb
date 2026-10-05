# frozen_string_literal: true

require "rails_helper"

# CYRA-855 — il ticket finto di serie non conia più un mondo intero a ogni chiamata.
#
# La factory creava sempre organizzazione, progetto, stato, priorità, autore e flusso agenti: 22
# query per ticket contro le 9 che bastano riusando ciò che la prova ha già in scena, su 326 file
# che creano ticket. Il riuso è invisibile leggendo la factory e si perde alla prima modifica
# distratta: queste prove lo tengono fermo.
RSpec.describe "Costo della factory :ticket" do
  # Un'organizzazione già arredata: la condizione normale di una prova che crea più di un ticket.
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization:) }
  let!(:status) { create(:ticket_status, organization:) }
  let!(:priority) { create(:ticket_priority, organization:) }
  let!(:member) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :member) }
  end

  def counters
    {
      organizations: Organizations::Organization.count,
      projects: Projects::Project.count,
      statuses: Types::TicketStatus.count,
      priorities: Types::TicketPriority.count,
      accounts: Accounts::Account.count,
      memberships: Connections::Membership.count,
      agent_workflows: Agents::Workflow.count
    }
  end

  it "non crea nessun dato di contorno quando l'organizzazione ne ha già" do
    before_counters = counters

    create(:ticket, organization:)

    expect(counters).to eq(before_counters)
  end

  it "aggancia il ticket al progetto, allo stato, alla priorità e all'autore già presenti" do
    ticket = create(:ticket, organization:)

    expect(ticket).to have_attributes(project:, status:, priority:, reporter: member)
  end

  it "riusa anche l'organizzazione quando la prova non ne indica una" do
    before_counters = counters

    ticket = create(:ticket)

    expect(ticket.project.organization).to eq(organization)
    expect(counters).to eq(before_counters)
  end

  it "resta sotto la metà delle ventidue query di prima" do
    create(:ticket, organization:) # riscaldamento: la prima create carica classi e statement cache

    queries = captured_queries { create(:ticket, organization:) }

    expect(queries.size).to be <= 11
  end

  # Uno stato concluso preso per sbaglio farebbe nascere "risolti" i ticket di serie: il riuso
  # guarda solo gli stati di apertura e, se non ce ne sono, ne conia uno.
  it "non riusa uno stato di chiusura" do
    Types::TicketStatus.destroy_all
    done = create(:ticket_status, :done, organization:)

    ticket = create(:ticket, organization:)

    expect(ticket.status).not_to eq(done)
    expect(ticket.status).to be_category_open
  end

  it "non conia il flusso agenti se nessuno lo chiede" do
    expect(create(:ticket, organization:).agent_workflow).to be_nil
  end

  it "conia il flusso agenti quando la prova lo chiede" do
    expect(create(:ticket, organization:, with_agent_workflow: true).agent_workflow).to be_present
  end
end
