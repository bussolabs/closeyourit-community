# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::BlockExhaustedPhase do
  let(:workflow) { create(:agent_workflow, :closer_staging_completed) }
  let(:organization) { workflow.ticket.project.organization }
  let(:limit) { Agents::Constants::PHASE_REVIEW_LIMIT }

  def attempt_with(status, phase: "closer_production")
    create(:agent_attempt, workflow:, organization:, phase:, status:)
  end

  it "blocca dopo il tetto di bocciature in review" do
    limit.times { attempt_with(:review_failed) }

    expect(described_class.call(attempt: workflow.attempts.last)).to be(true)
    expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_phase: "closer_production", blocked_kind: "attempt_limit")
  end

  # CYRA-504 — il buco che il tetto aveva: un tentativo che finisce senza un risultato interpretabile
  # non è una bocciatura, quindi non contava. La fase tornava reclamabile e si rifaceva all'infinito.
  it "conta anche i tentativi chiusi come falliti" do
    limit.times { attempt_with(:failed) }

    expect(described_class.call(attempt: workflow.attempts.last)).to be(true)
    expect(workflow.reload.blocked_at).to be_present
  end

  it "conta anche i tentativi scaduti" do
    limit.times { attempt_with(:stale) }

    expect(described_class.call(attempt: workflow.attempts.last)).to be(true)
    expect(workflow.reload.blocked_at).to be_present
  end

  it "conta insieme i modi diversi di fallire sulla stessa fase" do
    attempt_with(:review_failed)
    attempt_with(:stale)

    described_class.call(attempt: workflow.attempts.last)

    expect(workflow.reload.blocked_at).to be_present
  end

  it "sotto il tetto lascia la lavorazione libera di riprovare" do
    attempt = attempt_with(:failed)

    expect(described_class.call(attempt:)).to be(false)
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "non conta i fallimenti di un'altra fase" do
    limit.times { attempt_with(:failed, phase: "planner") }

    described_class.call(attempt: attempt_with(:failed))

    expect(workflow.reload.blocked_at).to be_nil
  end

  # Gli attempt sono audit immutabile e restano lì per sempre: contando tutta la storia il tentativo
  # concesso da un "riprova" sarebbe l'unico, e il blocco tornerebbe subito.
  it "riparte da zero dopo uno sblocco" do
    limit.times { attempt_with(:failed) }
    workflow.update!(review_budget_from: Time.current)
    fresco = attempt_with(:failed)

    expect(described_class.call(attempt: fresco)).to be(false)
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "non sovrascrive un blocco già scritto" do
    # `blocked_kind` è obbligatorio quando c'è un blocco (vincolo di tabella, CYRA-598): un blocco
    # senza autore rimetterebbe in piedi la frase che nomina la revisione anche quando a fermarsi è
    # stata la macchina.
    workflow.update!(blocked_at: 1.day.ago, blocked_phase: "planner", blocked_kind: "attempt_limit",
                     blocked_reason: "vecchio")
    limit.times { attempt_with(:failed) }

    expect(described_class.call(attempt: workflow.attempts.last)).to be(true)
    expect(workflow.reload).to have_attributes(blocked_phase: "planner", blocked_kind: "attempt_limit", blocked_reason: "vecchio")
  end

  # Il motivo è una riga di AUDIT, in una lingua sola e in forma stabile: la UI compone il testo
  # localizzato dai campi strutturati (fase e conteggio).
  it "scrive un motivo che dice fase e quante volte" do
    limit.times { attempt_with(:stale) }

    described_class.call(attempt: workflow.attempts.last)

    expect(workflow.reload.blocked_reason).to eq("attempt_limit: closer_production failed #{limit} times")
  end

  # Da qui dipende la frase mostrata a chi decide: quella del tetto nomina la revisione e conta le
  # bocciature, e su un blocco d'agente quel conteggio sarebbe zero.
  it "firma il blocco come dovuto al tetto dei tentativi" do
    limit.times { attempt_with(:stale) }

    described_class.call(attempt: workflow.attempts.last)

    expect(workflow.reload.blocked_kind).to eq("attempt_limit")
  end

  # ── CYRA-1327 ─────────────────────────────────────────────────────────────────────────────────
  #
  # The stop is the BRAKE, not the end of the story: the phase must stop being offered, and right
  # after the commit the budget is settled — over once on another engine, set aside the second time.
  describe "what happens after the stop" do
    it "asks for the budget to be settled" do
      limit.times { attempt_with(:stale) }

      expect { described_class.call(attempt: workflow.attempts.last) }
        .to have_enqueued_job(Agents::ExhaustedBudgetJob).with(workflow.id, String)
    end

    it "asks for nothing while the phase still has budget" do
      expect { described_class.call(attempt: attempt_with(:failed)) }
        .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)
    end

    # A stop already written is somebody else's story: the budget of this one was settled then.
    it "asks for nothing on a run that is already stopped" do
      workflow.update!(blocked_at: 1.day.ago, blocked_phase: "planner", blocked_kind: "attempt_limit",
                       blocked_reason: "old")
      limit.times { attempt_with(:failed) }

      expect { described_class.call(attempt: workflow.attempts.last) }
        .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)
    end

    # The server's own checkers do not produce attempts and never ran out of any: a red proposal or a
    # release that did not come up is a fact to look at, not an exhausted budget.
    it "asks for nothing when the stop comes from a checker" do
      expect do
        described_class.call(workflow:, phase: "autopilot", source: "candidate_check", reason: "checks_failing")
      end.not_to have_enqueued_job(Agents::ExhaustedBudgetJob)
    end
  end
  # ── CYRA-618 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Due ingressi, una porta sola. Il secondo non prende un `attempt:` e non è una scorciatoia: i
  # verificatori del server non producono tentativi, e fabbricarne di finti per riusare il primo
  # farebbe contare una storia che non c'è.
  describe "il secondo ingresso, senza tentativo" do
    let(:organization) { create(:organization) }
    let(:workflow) { create(:agent_workflow, organization:, triage_started_at: Time.current) }

    it "ferma subito, senza contare niente" do
      expect(described_class.call(workflow:, phase: "autopilot", source: "candidate_check",
                                  reason: "checks_failing on bussolabs/x#7")).to be(true)

      expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_phase: "autopilot",
                                                 blocked_kind: "candidate_check")
      expect(workflow.blocked_reason).to eq("candidate_check: checks_failing on bussolabs/x#7")
    end

    # Il tetto conta i tentativi di una fase; qui di tentativi non ce n'è, e contarli direbbe zero.
    it "non guarda il tetto: ferma anche senza nessun tentativo alle spalle" do
      expect(workflow.attempts).to be_empty

      described_class.call(workflow:, phase: "autopilot", source: "candidate_check", reason: "404")

      expect(workflow.reload.blocked_at).to be_present
    end

    # Una lavorazione già ferma resta ferma col motivo che aveva: il primo motivo è quello vero.
    it "non riscrive un blocco già scritto" do
      described_class.call(workflow:, phase: "autopilot", source: "candidate_check", reason: "primo")
      described_class.call(workflow:, phase: "closer_staging", source: "probe", reason: "secondo")

      expect(workflow.reload.blocked_reason).to include("primo")
    end

    it "senza i dati per scrivere il blocco solleva, invece di scrivere una riga a metà" do
      expect { described_class.call(workflow:, phase: "autopilot") }.to raise_error(ArgumentError)
      expect { described_class.call(workflow:, reason: "x") }.to raise_error(ArgumentError)
      expect(workflow.reload.blocked_at).to be_nil
    end
  end

  # ── CYRA-1330 ─────────────────────────────────────────────────────────────────────────────────
  #
  # A review that produced NO verdict — an exhausted quota, a reviewer process that died — says
  # nothing about the work: it says the MACHINE could not judge it. Counted as a rejection, two of
  # them stopped sound work and called a person for a fault nobody could act on.
  describe "a review that was never produced" do
    let(:fault_limit) { Agents::Constants::PHASE_REVIEW_FAULT_LIMIT }

    def fault_with(kind, at:, phase: "closer_production")
      create(:agent_attempt, workflow:, organization:, phase:, status: :failed,
                             review_fault: kind, created_at: at)
    end

    def last_attempt = workflow.attempts.order(:created_at).last

    # AC-4 — the fault does not charge the phase's attempts: two in a row leave the work going.
    it "spends no attempt on a technical fault" do
      limit.times { |n| fault_with("quota", at: (limit - n).minutes.ago) }

      expect(described_class.call(attempt: last_attempt)).to be(false)
      expect(workflow.reload.blocked_at).to be_nil
    end

    # AC-5 — `work`: the reviewer DID judge, and the answer belongs to this working copy. It counts
    # as it always has, because retrying the same copy gives the same answer forever.
    it "spends an attempt on a fault of the work itself" do
      limit.times { |n| fault_with("work", at: (limit - n).minutes.ago) }

      expect(described_class.call(attempt: last_attempt)).to be(true)
      expect(workflow.reload.blocked_kind).to eq("attempt_limit")
    end

    # AC-2 — real rejections keep their cap: a fault among them neither counts nor forgives.
    it "counts the rejections around a fault" do
      create(:agent_attempt, workflow:, organization:, phase: "closer_production",
                             status: :review_failed, created_at: 30.minutes.ago)
      fault_with("quota", at: 20.minutes.ago)
      rejected = create(:agent_attempt, workflow:, organization:, phase: "closer_production",
                                        status: :review_failed, created_at: 10.minutes.ago)

      expect(described_class.call(attempt: rejected)).to be(true)
      expect(workflow.reload.blocked_kind).to eq("attempt_limit")
    end

    # AC-3 / AC-6 — a cap of its own, and higher: a phase that only ever hits faults must stop
    # somewhere, or it waits and retries forever.
    it "stops a phase that keeps hitting faults, on a cap of its own" do
      fault_limit.times { |n| fault_with("transient", at: (fault_limit - n).minutes.ago) }

      expect(described_class.call(attempt: last_attempt)).to be(true)
      expect(workflow.reload).to have_attributes(blocked_kind: "review_fault",
                                                 blocked_phase: "closer_production")
      expect(workflow.blocked_reason)
        .to eq("review_fault: closer_production not judged #{fault_limit} times")
    end

    # The faults IN A ROW, not the ones of a lifetime. A delivery that got through breaks the
    # series: without that, the first fault of next week would count as the third of last month.
    it "counts the faults in a row" do
      fault_with("quota", at: 40.minutes.ago)
      create(:agent_attempt, workflow:, organization:, phase: "closer_production",
                             status: :approved, created_at: 30.minutes.ago)
      fault_with("quota", at: 20.minutes.ago)
      fault_with("quota", at: 10.minutes.ago)

      expect(described_class.call(attempt: last_attempt)).to be(false)
      expect(workflow.reload.blocked_at).to be_nil
    end

    # Same reason the rejections have a window: the attempts are immutable audit and stay there for
    # ever, so after an unblock the series has to start again from zero.
    it "starts the series again after an unblock" do
      fault_limit.times { |n| fault_with("quota", at: (60 - n).minutes.ago) }
      workflow.update!(review_budget_from: 10.minutes.ago)
      fresh = fault_with("transient", at: 1.minute.ago)

      expect(described_class.call(attempt: fresh)).to be(false)
      expect(workflow.reload.blocked_at).to be_nil
    end

    # CYRA-1327 settles a budget that RAN OUT: here nothing was spent, so there is no budget to
    # settle — starting the work over on another engine would not make a dead reviewer answer.
    it "settles no budget when nothing was spent" do
      fault_limit.times { |n| fault_with("quota", at: (fault_limit - n).minutes.ago) }

      expect { described_class.call(attempt: last_attempt) }
        .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)
    end
  end
end
