# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Split do
  let(:project) { create(:project) }
  let(:group) { create(:error_group, project:, events_count: 3, users_count: 2) }

  # Payload che producono un fingerprint REALE stabile e diverso da quello (fittizio) della factory.
  def alpha_payload = { "exception" => { "values" => [ { "type" => "AlphaError", "value" => "boom" } ] } }
  def beta_payload = { "exception" => { "values" => [ { "type" => "BetaError", "value" => "boom" } ] } }

  def split(events)
    described_class.call(group:, event_ids: Array(events).map(&:id))
  end

  it "sposta le occorrenze indicate in un nuovo gruppo dello stesso progetto" do
    a = create(:error_event, group:, project:)
    create_list(:error_event, 2, group:, project:)

    result = split(a)

    expect(result).to be_ok
    new_group = result.value
    expect(new_group.project_id).to eq(project.id)
    expect(a.reload.group_id).to eq(new_group.id)
    expect(group.reload.events.count).to eq(2)
  end

  it "il nuovo gruppo eredita l'identità descrittiva del sorgente" do
    group.update!(title: "RuntimeError: kaboom", culprit: "App::Y#call")
    a = create(:error_event, group:, project:)
    create(:error_event, group:, project:)

    new_group = split(a).value

    expect(new_group).to have_attributes(title: "RuntimeError: kaboom", culprit: "App::Y#call")
  end

  describe "contatori" do
    it "il nuovo gruppo conta le occorrenze spostate; il sorgente si decrementa" do
      moved = create_list(:error_event, 2, group:, project:, user_hash: "u1")
      create(:error_event, group:, project:, user_hash: "u2")

      new_group = split(moved).value

      expect(new_group.events_count).to eq(2)
      expect(new_group.users_count).to eq(1)          # solo u1 tra gli spostati
      expect(group.reload.events_count).to eq(1)      # 3 - 2 spostati
      expect(group.users_count).to eq(1)              # solo u2 resta
    end

    # CYRA-380: il sorgente aveva già ricevuto contesto utente (user_context_seen true), ma le
    # occorrenze con user_hash sono state potate: recount! azzera users_count. Il fatto storico NON deve
    # regredire, altrimenti un gruppo che aveva tracciato risulterebbe «non tracciato» dopo lo split.
    it "il sorgente resta «tracciato» anche se dopo lo split il conteggio utenti torna a zero" do
      group.update!(user_context_seen: true)
      moved = create(:error_event, group:, project:, user_hash: nil)
      create_list(:error_event, 2, group:, project:, user_hash: nil)

      split(moved)

      group.reload
      expect(group.users_count).to eq(0)
      expect(group.user_context_seen).to be(true)
    end

    it "il nuovo gruppo è «tracciato» sse le occorrenze spostate portano l'identità utente" do
      tracked_ev = create(:error_event, group:, project:, user_hash: "u1")
      plain_ev = create(:error_event, group:, project:, user_hash: nil)
      create(:error_event, group:, project:, user_hash: nil)

      expect(split(tracked_ev).value.user_context_seen).to be(true)   # occorrenza spostata con utente
      expect(split(plain_ev).value.user_context_seen).to be(false)    # occorrenza spostata senza utente
    end

    it "riallinea le finestre temporali di entrambi ai propri eventi" do
      old = create(:error_event, group:, project:, occurred_at: 5.days.ago)
      recent = create(:error_event, group:, project:, occurred_at: 1.hour.ago)

      new_group = split(old).value

      expect(new_group.first_seen_at).to be_within(1.second).of(5.days.ago)
      expect(new_group.last_seen_at).to be_within(1.second).of(5.days.ago)
      expect(group.reload.first_seen_at).to be_within(1.second).of(1.hour.ago)
      _ = recent
    end
  end

  describe "fingerprint del nuovo gruppo" do
    it "adotta il fingerprint reale se diverso dal sorgente e libero (la divisione tiene)" do
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      new_group = split(a).value

      expect(new_group.fingerprint).to eq(Errors::Fingerprint.call(payload: alpha_payload))
    end

    # Una nuova occorrenza di quel tipo finisce nel gruppo staccato, non nel sorgente: la prova che tiene.
    it "l'ingest successivo di quel tipo va nel gruppo staccato" do
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      new_group = split(a).value

      Errors::Ingest::Record.call(project:, payload: alpha_payload.merge("event_id" => SecureRandom.hex(16)))

      expect(new_group.reload.events.count).to eq(2)
    end

    it "usa una chiave sintetica se il fingerprint reale coincide col sorgente" do
      group.update!(fingerprint: Errors::Fingerprint.call(payload: alpha_payload))
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      new_group = split(a).value

      expect(new_group.fingerprint).to start_with("split:")
    end

    it "usa una chiave sintetica se il fingerprint reale è già di un altro gruppo" do
      create(:error_group, project:, fingerprint: Errors::Fingerprint.call(payload: alpha_payload))
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      new_group = split(a).value

      expect(new_group.fingerprint).to start_with("split:")
    end

    # Occorrenze estratte eterogenee → nessuna singola chiave le rappresenta → riorganizzazione storica.
    it "usa una chiave sintetica se le occorrenze estratte sono eterogenee" do
      a = create(:error_event, group:, project:, payload: alpha_payload)
      b = create(:error_event, group:, project:, payload: beta_payload)
      create(:error_event, group:, project:)

      new_group = split([ a, b ]).value

      expect(new_group.fingerprint).to start_with("split:")
    end

    # Il fingerprint adottato è quello EFFETTIVO: se una regola di raggruppamento rimappa quel tipo,
    # il nuovo gruppo prende la chiave della regola, non quella automatica — così tiene davvero.
    it "adotta il fingerprint effettivo, regole di raggruppamento comprese" do
      rule = create(:error_grouping_rule, project:, field: :exception_type, operator: :contains,
                                          value: "Alpha", fingerprint_key: "alphas")
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      new_group = split(a).value

      expect(new_group.fingerprint).to eq(rule.target_fingerprint)
    end

    # Unmerge di una singola chiave: il fingerprint estratto smette di essere risolto al sorgente.
    it "toglie dal sorgente il fingerprint assorbito che il nuovo gruppo adotta" do
      fp = Errors::Fingerprint.call(payload: alpha_payload)
      group.update!(merged_fingerprints: [ fp ])
      a = create(:error_event, group:, project:, payload: alpha_payload)
      create(:error_event, group:, project:)

      split(a)

      expect(group.reload.merged_fingerprints).not_to include(fp)
    end
  end

  describe "guardie" do
    it "rifiuta senza occorrenze" do
      result = described_class.call(group:, event_ids: [])

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-005")
    end

    # Tutto-o-niente: un'occorrenza estranea ferma tutto.
    it "con una lista che contiene un'occorrenza di un altro gruppo non divide niente" do
      mine = create(:error_event, group:, project:)
      other = create(:error_event, project:)

      result = described_class.call(group:, event_ids: [ mine.id, other.id ])

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-006")
      expect(mine.reload.group_id).to eq(group.id)
    end

    it "rifiuta di separare TUTTE le occorrenze (il gruppo resterebbe vuoto)" do
      events = create_list(:error_event, 2, group:, project:)

      result = split(events)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-007")
      expect(events.map { |e| e.reload.group_id }).to all(eq(group.id))
    end
  end
end
