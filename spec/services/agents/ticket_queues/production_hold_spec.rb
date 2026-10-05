# frozen_string_literal: true

require "rails_helper"

# CYRA-871 — la produzione parte solo dopo 2 ore di staging senza errori nuovi.
#
# Come per la fila dei rilasci (CYRA-595), due difese: la coda non propone il ticket, e la presa in
# carico ricontrolla sotto lock, perché fra la proposta e la presa può essere comparso un errore.
RSpec.describe "CYRA-871 — il freno prima della produzione" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) { host_ready_for(project) }

  before { versioni_uscite("v1.0.0") }

  def host_ready_for(target)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ target.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ target.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def provato_in_staging(da:, progetto: project)
    ticket = create(:ticket, :agent_workable, organization:, project: progetto, with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "closer_production")
    ticket.agent_workflow.update!(closer_staging_verified_at: da)
    create(:agent_attempt, workflow: ticket.agent_workflow, organization:, phase: "closer_staging",
                           status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "a" * 40 })
    ticket
  end

  def errore_in_staging(visto_da:, progetto: project, **attributi)
    group = create(:error_group, project: progetto, first_seen_at: visto_da, **attributi)
    create(:error_event, group:, environment: "staging", occurred_at: visto_da)
    group
  end

  def coda = Agents::TicketQueues::Candidates.new(project:, host:).head_id

  describe "la coda" do
    it "non propone la produzione prima di 2 ore dalla prova dello staging" do
      provato_in_staging(da: 119.minutes.ago)

      expect(coda).to be_nil
    end

    it "propone la produzione passate 2 ore senza errori nuovi" do
      ticket = provato_in_staging(da: 121.minutes.ago)

      expect(coda).to eq(ticket.id)
    end

    it "non la propone se dopo la prova è comparso un errore nuovo in staging" do
      provato_in_staging(da: 3.hours.ago)
      errore_in_staging(visto_da: 1.hour.ago)

      expect(coda).to be_nil
    end

    # La leva di chi decide: guardato l'errore, lo chiude o lo ignora e il rilascio riparte da solo.
    it "la ripropone appena l'errore viene risolto o ignorato" do
      ticket = provato_in_staging(da: 3.hours.ago)
      risolto = errore_in_staging(visto_da: 1.hour.ago)
      ignorato = errore_in_staging(visto_da: 1.hour.ago)
      expect(coda).to be_nil

      risolto.update!(status: :resolved)
      ignorato.update!(status: :ignored)

      expect(coda).to eq(ticket.id)
    end

    it "non conta gli errori che c'erano già prima della prova" do
      ticket = provato_in_staging(da: 3.hours.ago)
      vecchio = create(:error_group, project:, first_seen_at: 1.day.ago)
      create(:error_event, group: vecchio, environment: "staging", occurred_at: 1.hour.ago)

      expect(coda).to eq(ticket.id)
    end

    it "non conta gli errori nuovi della sola produzione" do
      ticket = provato_in_staging(da: 3.hours.ago)
      group = create(:error_group, project:, first_seen_at: 1.hour.ago)
      create(:error_event, group:, environment: "production", occurred_at: 1.hour.ago)

      expect(coda).to eq(ticket.id)
    end

    it "non conta gli errori di un altro progetto" do
      ticket = provato_in_staging(da: 3.hours.ago)
      errore_in_staging(visto_da: 1.hour.ago, progetto: create(:project, organization:))

      expect(coda).to eq(ticket.id)
    end

    # Il freno morde solo sull'ultimo passo: le altre fasi vanno avanti mentre il rilascio aspetta.
    it "le altre fasi continuano mentre il rilascio aspetta" do
      provato_in_staging(da: 10.minutes.ago)
      da_analizzare = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

      expect(coda).to eq(da_analizzare.id)
    end
  end

  describe "la presa in carico" do
    def prendi(ticket)
      token = Agents::TicketQueues::Selection.issue(ticket:, host:)
      Agents::TicketQueues::Claim.call(organization:, host:, selection_token: token,
                                       params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 })
    end

    it "rifiuta con un motivo suo se nel frattempo è comparso un errore nuovo in staging" do
      ticket = provato_in_staging(da: 3.hours.ago)
      token = Agents::TicketQueues::Selection.issue(ticket:, host:)
      group = errore_in_staging(visto_da: 1.hour.ago)

      esito = Agents::TicketQueues::Claim.call(organization:, host:, selection_token: token,
                                               params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 })

      expect(esito).to be_err
      expect(esito.error.code).to eq("R409-QUEUE-007")
      expect(esito.error.details).to include(reason: "staging_errors", error_group_id: group.id)
      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    it "prende in carico normalmente a freno libero" do
      ticket = provato_in_staging(da: 3.hours.ago)

      expect(prendi(ticket)).to be_ok
    end
  end
end

RSpec.describe Agents::Workflows::ProductionHold do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:now) { Time.current }

  def workflow_provato(da:)
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "closer_production")
    ticket.agent_workflow.tap { |w| w.update!(closer_staging_verified_at: da) }
  end

  it "dice fino a quando aspetta mentre lo staging è ancora in prova" do
    workflow = workflow_provato(da: 30.minutes.ago).reload
    hold = described_class.reason(workflow, now:)

    # L'ora riletta dal database: ha i microsecondi, non i nanosecondi dell'orologio.
    expect(hold).to eq(reason: "staging_soak", until: workflow.closer_staging_verified_at + described_class::WINDOW)
  end

  it "nomina l'errore che lo ferma" do
    workflow = workflow_provato(da: 3.hours.ago)
    group = create(:error_group, project:, first_seen_at: 1.hour.ago)
    create(:error_event, group:, environment: "staging", occurred_at: 1.hour.ago)

    expect(described_class.reason(workflow, now:)).to eq(reason: "staging_errors", error_group_id: group.id)
  end

  it "non trattiene niente a freno libero" do
    expect(described_class.reason(workflow_provato(da: 3.hours.ago), now:)).to be_nil
  end
end

# La scheda dice perché il rilascio aspetta: senza, «aspetta una macchina libera» sarebbe falso per
# due ore, e per sempre finché nessuno guarda l'errore.
RSpec.describe Member::AutomationSummary, "il motivo del freno" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }

  def provato_in_staging(da:)
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, "closer_production")
    ticket.agent_workflow.update!(closer_staging_verified_at: da)
    ticket
  end

  def frase(ticket, decides: true)
    described_class.new(workflow: ticket.agent_workflow.reload, attempts: [], decides:).stopped
  end

  def testo(chiave, **valori) = I18n.t("member.tickets.automation.summary.stopped.#{chiave}", **valori)

  it "durante la prova dello staging dice da che ora può partire" do
    ticket = provato_in_staging(da: 30.minutes.ago)

    verified = ticket.agent_workflow.reload.closer_staging_verified_at
    at = I18n.l(verified + Agents::Workflows::ProductionHold::WINDOW, format: :short)
    expect(frase(ticket)).to eq(testo("production_soak", at:))
  end

  it "con un errore nuovo in staging lo nomina a chi decide" do
    ticket = provato_in_staging(da: 3.hours.ago)
    group = create(:error_group, project:, title: "NoMethodError: boom", first_seen_at: 1.hour.ago)
    create(:error_event, group:, environment: "staging", occurred_at: 1.hour.ago)

    expect(frase(ticket)).to eq(testo("production_staging_error", title: group.title))
    expect(frase(ticket, decides: false)).to eq(testo("production_staging_error_anonymous"))
  end
end
