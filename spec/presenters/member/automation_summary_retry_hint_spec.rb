# frozen_string_literal: true

require "rails_helper"

# ── CYRA-626 ──────────────────────────────────────────────────────────────────────────────────────
#
# L'elenco e la scheda devono raccontare la stessa storia. Prima la scheda diceva «Non è ferma: ci
# sta lavorando adesso» mentre non stava lavorando nessuno, e alla domanda «Cosa serve da te»
# rispondeva «Niente: va avanti da sola» — vero solo per metà, perché da sola non ci andava.
RSpec.describe Member::AutomationSummary, "il guasto esterno" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:riprova_alle) { Time.zone.parse("2026-08-22 15:40") }
  let(:guasto) { Agents::Workflows::InFlight::RetryHint.new(code: "R502-GITHUB-001", at: riprova_alle) }

  def sintesi(retry_hint: nil)
    described_class.new(workflow: workflow.reload, attempts: [], decides: true,
                        cto_name: "Alessio", retry_hint:)
  end

  before { workflow.update!(triage_requested_at: 3.hours.ago, triage_started_at: 2.hours.ago) }

  it "dice il guasto e l'ora, e non più «ci sta lavorando adesso»" do
    I18n.with_locale(:it) do
      riga = sintesi(retry_hint: guasto).stopped

      expect(riga).to eq("Non è ferma: il sistema non riesce a leggere una cosa su GitHub " \
                         "(R502-GITHUB-001). Riprova alle #{I18n.l(riprova_alle, format: :short)}. " \
                         "Da te non serve niente.")
      expect(riga).not_to include("ci sta lavorando adesso")
    end
  end

  it "in inglese dice la stessa cosa, e non esce la chiave al posto del testo" do
    I18n.with_locale(:en) do
      riga = sintesi(retry_hint: guasto).stopped

      expect(riga).to include("R502-GITHUB-001")
      expect(riga).not_to include("translation missing")
      expect(riga).not_to include("stopped.retry_hint")
    end
  end

  # Il guasto non cambia CHI deve fare qualcosa: da chi legge non serve niente, e continua a non
  # servire. Dirlo diversamente lo manderebbe a cercare una decisione che non esiste.
  it "«cosa serve da te» resta «niente»" do
    expect(sintesi(retry_hint: guasto).needs).to eq(sintesi.needs)
  end

  # Senza guasto la riga è quella di sempre: la frase nuova non deve comparire per caso.
  it "senza guasto la riga è quella di prima" do
    I18n.with_locale(:it) { expect(sintesi.stopped).not_to include("Riprova alle") }
  end

  # ── Il ripiego diventa fail-closed ──────────────────────────────────────────────────────────────
  #
  # Ogni fase che il sistema sa produrre deve avere la sua riga. Con il ripiego di prima, una fase
  # nuova si raccontava come «ci sta lavorando adesso» — falso su qualunque fase di attesa, e nessuno
  # se ne accorgeva.
  it "ogni fase dichiarata dal dominio ha la sua riga, e nessuna ricade sul lavoro in corso" do
    senza_riga = Agents::Workflows::PhaseResolver::PHASES.reject do |fase|
      described_class::STOPPED_KEYS.key?(fase) ||
        %w[cancelled review_blocked closer_production_queued].include?(fase)
    end

    expect(senza_riga).to be_empty, "fasi senza riga «perché si è fermata»: #{senza_riga}"
  end

  # E il ripiego non c'è più: una fase che nessuno ha mappato fa rosso qui, invece di raccontarsi
  # come «ci sta lavorando adesso» — che su una fase di attesa è falso, e nessuno se ne accorgeva.
  it "una fase senza riga propria fa rosso, invece di dire che ci sta lavorando" do
    allow(workflow).to receive(:phase).and_return("fase_che_nessuno_ha_mappato")

    expect { sintesi.stopped }.to raise_error(KeyError)
  end
end
