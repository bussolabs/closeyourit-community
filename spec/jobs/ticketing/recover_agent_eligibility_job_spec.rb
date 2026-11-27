# frozen_string_literal: true

require "rails_helper"

# CYRA-847: un parere fallito durante un guasto del server AI non viene mai ritentato
# (R502-LLM-002 è definitivo), e il ticket resta senza parere per sempre.
RSpec.describe Ticketing::RecoverAgentEligibilityJob do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def create_ticket(status_trait = nil, **attributes)
    status = status_trait ? create(:ticket_status, status_trait, organization: organization)
                          : create(:ticket_status, organization: organization)
    create(:ticket, :team_created, organization: organization, project: project, status: status, **attributes)
  end

  # Il ticket "sano": valutato davvero, checksum allineato al contenuto.
  def mark_evaluated(ticket, advice: :allowed)
    ticket.update!(agent_eligibility_advice: advice,
                   agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: ticket))
  end

  it "è coda :batch" do
    expect(described_class.new.queue_name).to eq("batch")
  end

  it "riaccoda la valutazione di un ticket aperto rimasto senza parere" do
    ticket = create_ticket

    expect { described_class.perform_now }
      .to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).with(ticket_id: ticket.id)
  end

  # CYRA-1197, CYRA-1219
  it "turns a waiting favourable advice into the decision with the supporter and the automatic go-ahead on" do
    project.update!(supporter_enabled: true, auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")
    mark_evaluated(ticket)

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("allowed")
  end

  it "leaves a waiting negative advice to a person" do
    project.update!(supporter_enabled: true, auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")
    mark_evaluated(ticket, advice: :blocked)

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "does not approve an outdated favourable advice during recovery" do
    project.update!(supporter_enabled: true, auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")
    mark_evaluated(ticket)
    ticket.update!(title: "Sort the list by date")

    described_class.perform_now

    expect(ticket.reload).to be_agent_eligibility_pending
  end

  it "leaves the decision to a person with the automatic go-ahead off" do
    project.update!(supporter_enabled: true, auto_go_ahead_enabled: false)
    ticket = create_ticket(title: "Sort the list by name")
    mark_evaluated(ticket)

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "follows the automatic go-ahead's own switch on a project with the supporter off" do
    project.update!(supporter_enabled: false, auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")
    mark_evaluated(ticket)

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("allowed")
  end

  # AC-12 — the periodic round applies the same team rule as right after the advice.
  it "leaves a favourable advice on a help desk ticket to a person" do
    project.update!(auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")
    ticket.update_columns(origin: "helpdesk")
    mark_evaluated(ticket)

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  # AC-3 — without an advice the round asks again and never opens the ticket.
  it "gives no go-ahead to a ticket still without an advice" do
    project.update!(auto_go_ahead_enabled: true)
    ticket = create_ticket(title: "Sort the list by name")

    described_class.perform_now

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "non tocca un ticket già valutato" do
    ticket = create_ticket
    mark_evaluated(ticket)

    expect { described_class.perform_now }
      .not_to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob)
  end

  # La decisione umana è sticky: chiedere un parere costerebbe una chiamata al modello per
  # un'informazione che non entra più in nessuna scelta.
  it "non tocca un ticket con decisione umana" do
    ticket = create_ticket
    ticket.update!(agent_eligibility: :allowed, agent_eligibility_source: :human)

    expect { described_class.perform_now }
      .not_to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob)
  end

  it "non tocca un ticket chiuso: non entra comunque nella coda degli agenti" do
    create_ticket(:done)

    expect { described_class.perform_now }
      .not_to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob)
  end

  # Il parere c'è, è solo vecchio: il ticket è visibile e una persona può decidere. Rivalutarlo qui
  # farebbe passare dal giro orario l'intera rivalutazione del parco dopo un bump del prompt.
  it "non tocca un ticket il cui parere esiste ma è vecchio" do
    ticket = create_ticket
    mark_evaluated(ticket)
    ticket.update!(title: "Titolo cambiato dopo la valutazione")

    expect { described_class.perform_now }
      .not_to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob)
  end

  describe "tetto per giro" do
    it "non accoda più ticket del tetto" do
      3.times { create_ticket }
      stub_const("Ticketing::Constants::AGENT_ELIGIBILITY_RECOVERY_PER_RUN", 2)

      expect { described_class.perform_now }
        .to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).exactly(2).times
    end

    # Il primo backfill reale ha saturato il rate limit del fornitore in pochi secondi: i job del
    # giro partono cadenzati, non tutti insieme.
    it "cadenza gli accodamenti invece di lanciarli tutti nello stesso istante" do
      (Ticketing::Constants::AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE + 1).times { create_ticket }

      described_class.perform_now

      waits = ActiveJob::Base.queue_adapter.enqueued_jobs
                             .select { |job| job[:job] == Ticketing::EvaluateAgentEligibilityJob }
                             .map { |job| job[:at] }
      expect(waits.compact.uniq.size).to be > 1
    end
  end

  describe "config/recurring.yml" do
    let(:entry) do
      raw = ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result
      YAML.safe_load(raw, aliases: true).fetch("production")["recover_agent_eligibility"]
    end

    it "schedula il giro di recupero" do
      expect(entry).to be_present, "config/recurring.yml non schedula il recupero dei pareri mancanti"
      expect(entry["class"]).to eq(described_class.name)
      expect(entry["queue"]).to eq("batch")
    end
  end
end
