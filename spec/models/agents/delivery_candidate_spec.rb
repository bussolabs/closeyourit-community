# frozen_string_literal: true

require "rails_helper"

# CYRA-604 — il registro di cosa il sistema ha guardato. Da solo non cambia niente di visibile: è il
# quaderno su cui i lavori successivi scriveranno. Ma da com'è fatto dipendono tre cose, e sono tutte
# e tre provate qui perché nessuna si può recuperare dopo.
RSpec.describe Agents::DeliveryCandidate do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:) }

  def candidate(*traits, **overrides) = create(:agent_delivery_candidate, *traits, workflow:, organization:, **overrides)

  # PRIMA: la riga nasce prima che si sappia quale codice c'è dentro la proposta. Se il quaderno
  # pretendesse quel dato alla nascita, il passo che registra la consegna non potrebbe nemmeno
  # cominciare e la catena si fermerebbe alla prima riga.
  describe "nasce prima di sapere il codice" do
    it "si salva senza head_sha, base_ref, verified_at e checks_payload" do
      riga = candidate

      expect(riga).to be_persisted
      expect(riga.head_sha).to be_nil
      expect(riga.base_ref).to be_nil
      expect(riga.verified_at).to be_nil
      expect(riga.checks_payload).to be_nil
      expect(riga.state).to eq("pending")
    end

    # Il vincolo di forma vale SOLO sugli stati verificati: una riga verificata senza codice, ramo,
    # ora ed esito dice «ho guardato» senza dire cosa, e non è la prova di niente.
    it "rifiuta a livello di database una riga verificata senza il codice che dice di aver guardato" do
      riga = candidate

      expect {
        riga.update_columns(state: 1, verified_at: Time.current, checks_payload: [])
      }.to raise_error(ActiveRecord::StatementInvalid, /verified_complete/)
    end

    it "accetta la riga verificata quando porta tutto" do
      expect(candidate(:verified_passing)).to be_persisted
    end
  end

  # SECONDA: scritto l'esito, la riga non si tocca più. È la prova di cosa hai approvato: se qualcuno
  # potesse riscriverla, fra un mese non ci sarebbe più modo di sapere su quale codice avevi detto sì.
  describe "l'esito scritto non si riscrive" do
    it "solleva su qualunque aggiornamento di una riga già verificata" do
      riga = candidate(:verified_passing)

      expect { riga.update!(last_error_code: "qualcosa") }
        .to raise_error(ActiveRecord::ReadOnlyRecord, /prova di cosa è stato approvato/)
    end

    # La guardia scatta sul valore GIÀ SALVATO, non su quello in memoria: deve lasciar passare la
    # scrittura che segna l'esito la prima volta — è quella per cui il registro esiste.
    it "lascia scrivere l'esito la prima volta" do
      riga = candidate

      expect {
        riga.update!(state: :verified_passing, head_sha: "a" * 40, base_ref: "main",
                     verified_at: Time.current, checks_payload: [])
      }.not_to raise_error
      expect(riga.reload.state).to eq("verified_passing")
    end

    # `attr_readonly` farebbe la stessa cosa in apparenza e romperebbe proprio la scrittura giusta:
    # con load_defaults 8.1 solleva su una riga già salvata. Se qualcuno lo rimettesse, questo
    # diventa rosso.
    it "non usa attr_readonly, che bloccherebbe anche la scrittura giusta" do
      expect(described_class.readonly_attributes).not_to include("verified_at", "head_sha", "state")
    end
  end

  # TERZA: la stessa proposta non finisce due volte nel quaderno con due esiti diversi — la scheda ne
  # mostrerebbe uno a caso. Ma se dopo il controllo il codice cambia, nasce una riga nuova accanto
  # alla vecchia, che resta come prova.
  describe "una proposta, una riga per ogni codice" do
    it "rifiuta il doppione sulla stessa proposta con lo stesso codice" do
      candidate(:verified_passing, number: 7)

      expect { candidate(:verified_passing, number: 7) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # Qui `nulls_not_distinct` è tutto: col comportamento normale di Postgres due righe con SHA nullo
    # sarebbero entrambe ammesse, ed è ESATTAMENTE il momento in cui il doppione nasce — la riga
    # appena creata, prima che qualcuno abbia guardato.
    it "rifiuta il doppione anche quando il codice non si sa ancora" do
      candidate(number: 9)

      expect { candidate(number: 9) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "ammette una riga nuova sul codice nuovo, accanto a quella vecchia" do
      vecchia = candidate(:verified_passing, number: 11, head_sha: "a" * 40)
      nuova = candidate(:verified_passing, number: 11, head_sha: "b" * 40)

      expect(described_class.where(number: 11).count).to eq(2)
      expect(vecchia.reload.head_sha).to eq("a" * 40)
      expect(nuova.head_sha).to eq("b" * 40)
    end
  end

  # Il cuore del disegno: «ho guardato e non c'è nessun controllo configurato» non è «non sono
  # riuscito a guardare». La prima passa, la seconda si aspetta e si riprova.
  describe "i due modi di non avere controlli" do
    it "distingue l'elenco vuoto dal mai guardato" do
      mai = candidate
      guardato = candidate(:verified_none_configured, number: 21)

      expect(mai.checks_payload).to be_nil
      expect(mai.checked?).to be(false)
      expect(guardato.checks_payload).to eq([])
      expect(guardato.checked?).to be(true)
    end

    # `checks_payload.present?` risponderebbe «mai guardato» su un elenco vuoto, perché `[]` è
    # `blank?`: proprio il caso che questo registro esiste per distinguere.
    it "non confonde «guardato, zero controlli» con «mai guardato»" do
      expect(candidate(:verified_none_configured).checks_payload).to be_blank
      expect(candidate(:verified_none_configured, number: 31).checked?).to be(true)
    end

    it "«non sono riuscito a guardare» resta ritentabile e non è un esito" do
      riga = candidate(:unreachable)

      expect(riga.state).to eq("unreachable")
      expect(riga.checked?).to be(false)
      expect(described_class.retryable).to include(riga)
      expect(described_class.due(1.hour.from_now)).to include(riga)
    end

    it "un esito verificato non torna mai fra le ritentabili" do
      expect(described_class.retryable).not_to include(candidate(:verified_none_configured))
    end
  end

  # La cosa più brutta da cui questo registro protegge: una consegna che nomina un progetto che non è
  # dell'organizzazione della lavorazione. Non si ignora in silenzio e non si punta mai a roba altrui.
  describe "il progetto agganciato è dell'organizzazione della lavorazione" do
    it "rifiuta un repository di un'altra organizzazione" do
      altrui = create(:github_repository, project: create(:project, organization: create(:organization)))

      riga = build(:agent_delivery_candidate, workflow:, organization:, repository: altrui)

      expect(riga).not_to be_valid
      expect(riga.errors[:repository_id]).to include(/non appartiene/)
    end

    it "accetta un repository della stessa organizzazione" do
      mio = create(:github_repository, project: create(:project, organization:))

      expect(build(:agent_delivery_candidate, workflow:, organization:, repository: mio)).to be_valid
    end

    # La riga rifiutata non aggancia niente ma dice comunque di cosa parlava: senza il nome osservato
    # sarebbe una riga muta.
    it "la riga rifiutata conserva il nome osservato e il motivo, senza chiave verso nessuno" do
      riga = candidate(:rejected)

      expect(riga.repository_id).to be_nil
      expect(riga.repository_full_name).to be_present
      expect(riga.last_error_code).to be_present
    end
  end
end
