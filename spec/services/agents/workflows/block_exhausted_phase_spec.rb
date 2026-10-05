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
end
