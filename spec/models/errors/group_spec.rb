# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Group, type: :model do
  describe "factory" do
    it "produce un gruppo valido" do
      expect(build(:error_group)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede fingerprint" do
      expect(build(:error_group, fingerprint: nil)).not_to be_valid
    end

    it "richiede title" do
      expect(build(:error_group, title: nil)).not_to be_valid
    end

    it "fingerprint unico per progetto" do
      group = create(:error_group)
      dup = build(:error_group, project: group.project, fingerprint: group.fingerprint)
      expect(dup).not_to be_valid
    end

    it "permette lo stesso fingerprint in progetti diversi" do
      group = create(:error_group)
      other = build(:error_group, project: create(:project), fingerprint: group.fingerprint)
      expect(other).to be_valid
    end

    # CYRA-153: isolamento tenant sull'assignee (come Ticketing::Ticket).
    describe "assignee" do
      let(:org) { create(:organization) }
      let(:project) { create(:project, organization: org) }

      it "accetta un assegnatario membro dell'org del progetto" do
        member = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
        expect(build(:error_group, project:, assignee: member)).to be_valid
      end

      it "rifiuta un assegnatario che non è membro dell'org (anti-BOLA)" do
        outsider = create(:account)
        group = build(:error_group, project:, assignee: outsider)
        expect(group).not_to be_valid
        expect(group.errors[:assignee]).to be_present
      end

      it "resta valido senza assegnatario" do
        expect(build(:error_group, project:, assignee: nil)).to be_valid
      end
    end
  end

  describe "enum status" do
    it "transita unresolved → resolved → ignored" do
      group = create(:error_group)
      expect(group).to be_status_unresolved
      group.status_resolved!
      expect(group.reload).to be_status_resolved
      group.status_ignored!
      expect(group.reload).to be_status_ignored
    end
  end

  describe "associazioni eventi (0/1/N + cascade)" do
    it "0 eventi: gruppo valido, nessun evento" do
      expect(create(:error_group).events).to be_empty
    end

    it "N eventi e cascade alla distruzione del gruppo" do
      group = create(:error_group)
      create_list(:error_event, 2, group: group, project: group.project)
      expect(group.events.count).to eq(2)
      expect { group.destroy }.to change(Errors::Event, :count).by(-2)
    end
  end

  describe "#promoted?" do
    it "false senza ticket, true con ticket" do
      expect(build(:error_group, ticket: nil).promoted?).to be(false)
      ticket = create(:ticket)
      group = create(:error_group, project: ticket.project, ticket: ticket)
      expect(group.promoted?).to be(true)
    end
  end

  # CYRA-380: «ha MAI ricevuto il contesto utente» è un fatto storico (user_context_seen), NON derivato
  # da users_count — che è un lower-bound azzerabile da Errors::Split#recount!/potatura. Il predicato
  # dipende solo dal flag, così un gruppo che ha tracciato non ricade in «non tracciato» dopo lo split.
  describe "#user_context_tracked?" do
    it "false quando il gruppo non ha mai ricevuto il contesto utente" do
      expect(build(:error_group, user_context_seen: false).user_context_tracked?).to be(false)
    end

    it "true quando il gruppo ha ricevuto il contesto utente almeno una volta" do
      expect(build(:error_group, user_context_seen: true).user_context_tracked?).to be(true)
    end

    it "resta true anche se il conteggio utenti è tornato a zero (post-split/potatura): non è un proxy di users_count" do
      group = build(:error_group, user_context_seen: true, users_count: 0)
      expect(group.user_context_tracked?).to be(true)
    end
  end

  describe ".recent" do
    it "ordina per last_seen_at desc" do
      org = create(:organization)
      project = create(:project, organization: org)
      older = create(:error_group, project: project, last_seen_at: 2.hours.ago)
      newer = create(:error_group, project: project, last_seen_at: 1.minute.ago)
      expect(described_class.where(project: project).recent.to_a).to eq([ newer, older ])
    end
  end

  describe ".buckets_for (istogramma occorrenze)" do
    let(:project) { create(:project) }
    let(:group) { create(:error_group, project: project) }

    it "conta le occorrenze per bucket temporale (somma = totale nel range)" do
      now = Time.utc(2026, 6, 1, 12)
      create(:error_event, group: group, project: project, occurred_at: now - 5.minutes)
      create(:error_event, group: group, project: project, occurred_at: now - 5.minutes)
      create(:error_event, group: group, project: project, occurred_at: now - 90.minutes)

      buckets = described_class.buckets_for(group.id, "24h", now)[group.id]
      expect(buckets.size).to eq(48)
      expect(buckets.sum { |b| b[:count] }).to eq(3)
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      now = Time.utc(2026, 6, 27, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:error_event, group: group, project: project, occurred_at: now - 5.minutes)

      buckets = described_class.buckets_for(group.id, "24h", now)[group.id]
      expect(buckets.last[:count]).to eq(1)
      expect(buckets[-2][:count]).to eq(0)
    end

    it "gruppo senza eventi → tutti i bucket a 0" do
      buckets = described_class.buckets_for(group.id, "24h", Time.current)[group.id]
      expect(buckets.size).to eq(48)
      expect(buckets).to all(include(count: 0))
      expect(buckets).to all(include(:at))
    end

    it "dimensione bucket per range" do
      now = Time.current
      expect(described_class.buckets_for(group.id, "30m", now)[group.id].size).to eq(30)
      expect(described_class.buckets_for(group.id, "7d", now)[group.id].size).to eq(56)
      expect(described_class.buckets_for(group.id, "30d", now)[group.id].size).to eq(30)
    end

    it "esclude le occorrenze fuori dal range" do
      now = Time.utc(2026, 6, 1, 12)
      create(:error_event, group: group, project: project, occurred_at: now - 2.days)
      buckets = described_class.buckets_for(group.id, "24h", now)[group.id]
      expect(buckets.sum { |b| b[:count] }).to eq(0)
    end

    it "range sconosciuto → default 24h (48 bucket)" do
      expect(described_class.buckets_for(group.id, "bogus", Time.current)[group.id].size).to eq(48)
    end

    it "ritorna {} quando la lista di id è vuota (ids.blank?)" do
      expect(described_class.buckets_for([], "24h")).to eq({})
    end

    # CYRA-562 — il dettaglio errore passa qui lo STESSO insieme che mostra nella tabella sotto,
    # così il grafico non può più contraddirla.
    describe "insieme di occorrenze ristretto (events:)" do
      it "conta solo le occorrenze dell'insieme passato" do
        now = Time.utc(2026, 6, 1, 12)
        create(:error_event, group: group, project: project, environment: "production", occurred_at: now - 5.minutes)
        create(:error_event, group: group, project: project, environment: "staging", occurred_at: now - 5.minutes)

        buckets = described_class.buckets_for(group.id, "24h", now,
                                              events: Errors::Event.where(environment: "staging"))[group.id]
        expect(buckets.sum { |b| b[:count] }).to eq(1)
      end

      it "insieme senza corrispondenze → tutti i blocchi a 0" do
        now = Time.utc(2026, 6, 1, 12)
        create(:error_event, group: group, project: project, environment: "production", occurred_at: now - 5.minutes)

        buckets = described_class.buckets_for(group.id, "24h", now,
                                              events: Errors::Event.where(environment: "staging"))[group.id]
        expect(buckets).to all(include(count: 0))
      end

      # La scope della tabella arriva ordinata: un ORDER BY su colonna non aggregata farebbe fallire
      # la GROUP BY in Postgres, quindi l'ordinamento va tolto qui e non ricordato dal chiamante.
      it "accetta un insieme già ordinato senza rompere il raggruppamento" do
        now = Time.utc(2026, 6, 1, 12)
        create(:error_event, group: group, project: project, occurred_at: now - 5.minutes)

        buckets = described_class.buckets_for(group.id, "24h", now,
                                              events: Errors::Event.order(occurred_at: :desc))[group.id]
        expect(buckets.sum { |b| b[:count] }).to eq(1)
      end
    end
  end

  describe ".current_embedding (CYRA-168)" do
    it "tiene solo le righe della versione di embedding corrente, escludendo altra versione e nil" do
      current = create(:error_group)
      current.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
      stale = create(:error_group)
      stale.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")
      never_embedded = create(:error_group) # embedding_version nil

      ids = described_class.current_embedding.pluck(:id)

      expect(ids).to include(current.id)
      expect(ids).not_to include(stale.id, never_embedded.id)
    end
  end
end
