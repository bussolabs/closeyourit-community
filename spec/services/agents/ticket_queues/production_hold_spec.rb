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

    # CYRA-1000 — scenario 6: at 0 hours the claim still re-checks new staging errors.
    it "refuses a 0-hour release when a new staging error appeared" do
      project.update!(production_hold_hours: 0)
      ticket = provato_in_staging(da: 1.minute.ago)
      group = errore_in_staging(visto_da: 30.seconds.ago)

      esito = prendi(ticket)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R409-QUEUE-007")
      expect(esito.error.details).to include(reason: "staging_errors", error_group_id: group.id)
    end

    it "claims a 0-hour release right after the staging check" do
      project.update!(production_hold_hours: 0)
      ticket = provato_in_staging(da: 1.minute.ago)

      expect(prendi(ticket)).to be_ok
    end

    it "refuses a release still inside the organization's wait" do
      organization.update!(production_hold_hours: 4)
      ticket = provato_in_staging(da: 3.hours.ago)

      esito = prendi(ticket)

      expect(esito).to be_err
      expect(esito.error.details).to include(reason: "staging_soak")
    end
  end

  # CYRA-1000 — the wait is picked on project, organization or platform: the closest level wins,
  # 2 hours when none picks, 0 skips the wait but never the check for new staging errors.
  describe "the configurable wait in the queue" do
    let(:global) { Settings::Global.instance }

    # Scenario 1.
    it "waits the fallback 2 hours when no level picks a wait" do
      provato_in_staging(da: 1.hour.ago)

      expect(coda).to be_nil
    end

    # Scenario 2.
    it "uses the project's wait over the organization's and the platform's" do
      project.update!(production_hold_hours: 6)
      organization.update!(production_hold_hours: 24)
      global.update!(production_hold_hours: 48)
      ticket = provato_in_staging(da: 7.hours.ago)

      expect(coda).to eq(ticket.id)
    end

    # Scenario 3.
    it "uses the organization's wait when the project picks none" do
      organization.update!(production_hold_hours: 4)
      ticket = provato_in_staging(da: 3.hours.ago)

      expect(coda).to be_nil

      ticket.agent_workflow.update!(closer_staging_verified_at: 241.minutes.ago)
      expect(coda).to eq(ticket.id)
    end

    # Scenario 4.
    it "uses the platform's wait when project and organization pick none" do
      global.update!(production_hold_hours: 1)
      ticket = provato_in_staging(da: 90.minutes.ago)

      expect(coda).to eq(ticket.id)
    end

    # Scenario 5.
    it "starts a 0-hour release right after the staging check" do
      project.update!(production_hold_hours: 0)
      ticket = provato_in_staging(da: 1.minute.ago)

      expect(coda).to eq(ticket.id)
    end

    # Scenario 6.
    it "still holds a 0-hour release on a new staging error" do
      project.update!(production_hold_hours: 0)
      provato_in_staging(da: 1.minute.ago)
      errore_in_staging(visto_da: 30.seconds.ago)

      expect(coda).to be_nil
    end

    # Scenario 7: a saved 0 is a choice, not a blank that inherits.
    it "does not read a project's 0 as blank" do
      project.update!(production_hold_hours: 0)
      organization.update!(production_hold_hours: 24)
      ticket = provato_in_staging(da: 1.minute.ago)

      expect(coda).to eq(ticket.id)
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
    expect(hold).to eq(reason: "staging_soak", until: workflow.closer_staging_verified_at + described_class::DEFAULT_HOURS.hours)
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

  describe ".hours" do
    let(:global) { Settings::Global.instance }

    it "falls back to 2 hours when no level picks a wait" do
      expect(described_class.hours(project)).to eq(2)
    end

    it "takes the first level that picks: project, organization, platform" do
      global.update!(production_hold_hours: 48)
      expect(described_class.hours(project.reload)).to eq(48)

      organization.update!(production_hold_hours: 24)
      expect(described_class.hours(project.reload)).to eq(24)

      project.update!(production_hold_hours: 6)
      expect(described_class.hours(project.reload)).to eq(6)
    end

    it "keeps a project's 0 over the organization's value" do
      organization.update!(production_hold_hours: 24)
      project.update!(production_hold_hours: "0")

      expect(described_class.hours(project.reload)).to eq(0)
    end

    it "keeps an organization's 0 over the platform's value" do
      global.update!(production_hold_hours: 48)
      organization.update!(production_hold_hours: 0)

      expect(described_class.hours(project.reload)).to eq(0)
    end
  end

  describe ".reason with a configured wait" do
    it "says until when it waits with the organization's wait" do
      organization.update!(production_hold_hours: 4)
      workflow = workflow_provato(da: 3.hours.ago).reload

      expect(described_class.reason(workflow, now:))
        .to eq(reason: "staging_soak", until: workflow.closer_staging_verified_at + 4.hours)
    end

    it "holds nothing at 0 hours without new staging errors" do
      project.update!(production_hold_hours: 0)

      expect(described_class.reason(workflow_provato(da: 1.minute.ago), now:)).to be_nil
    end

    it "names the new staging error at 0 hours" do
      project.update!(production_hold_hours: 0)
      workflow = workflow_provato(da: 1.minute.ago)
      group = create(:error_group, project:, first_seen_at: 30.seconds.ago)
      create(:error_event, group:, environment: "staging", occurred_at: 30.seconds.ago)

      expect(described_class.reason(workflow, now:)).to eq(reason: "staging_errors", error_group_id: group.id)
    end
  end
end

# CYRA-1000 — scenario 8: every level accepts 0..72 whole hours or blank, and refuses the rest with a
# clear message.
RSpec.describe "CYRA-1000 — the wait before production is validated on every level" do
  let(:organization) { create(:organization) }
  let(:message) { I18n.t("errors.messages.production_hold_hours") }

  def records
    [ create(:project, organization:), organization, Settings::Global.instance ]
  end

  it "accepts whole hours from 0 to 72, and blank as inherit" do
    records.each do |record|
      %w[0 1 72].each do |value|
        record.production_hold_hours = value
        expect(record).to be_valid, "#{record.class} #{value}: #{record.errors.full_messages}"
        expect(record.production_hold_hours).to eq(value.to_i)
      end
      record.production_hold_hours = ""
      expect(record).to be_valid
      expect(record.production_hold_hours).to be_nil
    end
  end

  it "refuses 73, negative and fractional hours with a clear message" do
    records.each do |record|
      %w[73 -1 1.5 abc].each do |value|
        record.production_hold_hours = value
        expect(record).not_to be_valid, "#{record.class} #{value}"
        expect(record.errors[:production_hold_hours]).to eq([ message ])
      end
    end
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
    at = I18n.l(verified + Agents::Workflows::ProductionHold::DEFAULT_HOURS.hours, format: :short)
    expect(frase(ticket)).to eq(testo("production_soak", at:))
  end

  it "con un errore nuovo in staging lo nomina a chi decide" do
    ticket = provato_in_staging(da: 3.hours.ago)
    group = create(:error_group, project:, title: "NoMethodError: boom", first_seen_at: 1.hour.ago)
    create(:error_event, group:, environment: "staging", occurred_at: 1.hour.ago)

    expect(frase(ticket)).to eq(testo("production_staging_error", title: group.title))
    expect(frase(ticket, decides: false)).to eq(testo("production_staging_error_anonymous"))
  end

  # CYRA-1000 — the card follows the same resolver as the queue.
  it "says the time from the project's own wait" do
    project.update!(production_hold_hours: 6)
    ticket = provato_in_staging(da: 3.hours.ago)

    verified = ticket.agent_workflow.reload.closer_staging_verified_at
    expect(frase(ticket)).to eq(testo("production_soak", at: I18n.l(verified + 6.hours, format: :short)))
  end

  it "says no time at 0 hours, only that it waits for a free machine" do
    project.update!(production_hold_hours: 0)
    ticket = provato_in_staging(da: 1.minute.ago)

    expect(frase(ticket)).to eq(testo("queued"))
  end

  # Scenario 6.
  it "names the new staging error at 0 hours" do
    project.update!(production_hold_hours: 0)
    ticket = provato_in_staging(da: 1.minute.ago)
    group = create(:error_group, project:, title: "NoMethodError: boom", first_seen_at: 30.seconds.ago)
    create(:error_event, group:, environment: "staging", occurred_at: 30.seconds.ago)

    expect(frase(ticket)).to eq(testo("production_staging_error", title: group.title))
  end
end
