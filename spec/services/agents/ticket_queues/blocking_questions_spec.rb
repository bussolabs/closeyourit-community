# frozen_string_literal: true

require "rails_helper"

# ── CYRA-781 ──────────────────────────────────────────────────────────────────────────────────────
#
# Una domanda dichiarata bloccante ferma il lavoro su quel ticket. La coda non si ferma: SALTA il
# ticket e serve il primo lavoro buono che c'è sotto, esattamente come fa coi prerequisiti — e il
# ticket rientra da sé appena qualcuno risponde, senza che nessuno debba togliere una leva.
#
# Il blocco è del TICKET, non della fase in cui la domanda è nata: chi ha detto «senza risposta non si
# prosegue» non parlava del passo in corso.
RSpec.describe "coda e domande bloccanti", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) do
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA",
                                                     project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end
  let(:autore) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  before { versioni_uscite("v0.1.0") }

  def ticket_pronto(numero_priorita: 0)
    ticket = create(:ticket, :agent_workable, organization:, project:,
                             priority: create(:ticket_priority, organization:, position: numero_priorita), with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "triage")
    ticket
  end

  def domanda(ticket, blocking:, **attributi)
    Ticketing::Question.create!(ticket:, author: autore, body: "Quale strada?", blocking:, **attributi)
  end

  def coda_next = Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:)

  it "senza domande aperte il ticket viene servito" do
    atteso = ticket_pronto

    expect(coda_next.value).to eq(atteso)
  end

  it "una domanda bloccante senza risposta fa saltare il ticket, e la coda serve quello sotto" do
    trattenuto = ticket_pronto(numero_priorita: 10)
    domanda(trattenuto, blocking: true)
    libero = ticket_pronto(numero_priorita: 5)

    expect(coda_next.value).to eq(libero)
  end

  it "il salto non lascia dietro di sé né prese in carico né tentativi" do
    trattenuto = ticket_pronto
    domanda(trattenuto, blocking: true)

    expect { coda_next }.not_to change { Agents::Attempt.where(workflow_id: trattenuto.agent_workflow.id).count }
    expect(Agents::Lease.where(ticket_id: trattenuto.id)).to be_empty
  end

  it "una domanda NON bloccante non trattiene niente" do
    atteso = ticket_pronto
    domanda(atteso, blocking: false)

    expect(coda_next.value).to eq(atteso)
  end

  it "risposto, il ticket rientra da solo" do
    ticket = ticket_pronto
    riga = domanda(ticket, blocking: true)
    expect(coda_next.value).to be_nil

    Ticketing::Questions::Answer.call(question: riga, author: autore, body: "Quella di sinistra.")

    expect(coda_next.value).to eq(ticket)
  end

  it "ritirata, il ticket rientra da solo" do
    ticket = ticket_pronto
    riga = domanda(ticket, blocking: true)
    expect(coda_next.value).to be_nil

    Ticketing::Questions::Close.call(question: riga, actor: autore)

    expect(coda_next.value).to eq(ticket)
  end
end
