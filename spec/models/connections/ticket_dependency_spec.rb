# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::TicketDependency, type: :model do
  let(:organization) { create(:organization) }
  # A dipende da B: A è `ticket`, B è `blocker` (prerequisito). Nomi coerenti con gli scenari del ticket.
  let(:ticket_a) { create(:ticket, organization:) }
  let(:ticket_b) { create(:ticket, organization:) }

  # Ticket con uno status "done" (category done): un blocker done non blocca più il dipendente.
  def done_ticket
    create(:ticket, organization:, status: create(:ticket_status, :done, organization:))
  end

  describe "validazioni" do
    it "è valida con ticket, blocker e created_by" do
      expect(build(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)).to be_valid
    end

    # CYRA-596 — un prerequisito lo mette una PERSONA, e questo è il punto che nessun canale aggira.
    # Prima era valida senza autore: bastava costruire la riga per scavalcare qualunque controllo
    # scritto nei servizi.
    it "non nasce senza autore" do
      dipendenza = build(:ticket_dependency, ticket: ticket_a, blocker: ticket_b, created_by: nil)

      expect(dipendenza).not_to be_valid
      expect(dipendenza.errors).to be_of_kind(:created_by, :blank)
    end

    it "non nasce da un'utenza di programma" do
      programma = create(:account, kind: :service)
      dipendenza = build(:ticket_dependency, ticket: ticket_a, blocker: ticket_b, created_by: programma)

      expect(dipendenza).not_to be_valid
      expect(dipendenza.errors).to be_of_kind(:created_by, :must_be_human)
    end

    # L'altra metà, e serve: `created_by` è una FK `nullify`. Un legame deciso mesi fa da qualcuno
    # che ha lasciato l'organizzazione deve restare valido, leggibile e rimovibile — una validazione
    # su ogni salvataggio lo renderebbe impossibile da toccare, e resterebbe lì per sempre.
    it "resta valida se l'autore viene cancellato dopo" do
      dipendenza = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      dipendenza.update_column(:created_by_id, nil)

      expect(dipendenza.reload).to be_valid
      expect { dipendenza.destroy! }.to change(described_class, :count).by(-1)
    end

    it "ammette la dipendenza cross-project ma intra-organizzazione" do
      other_project = create(:project, organization:)
      app_ticket = create(:ticket, organization:, project: other_project)
      dependency = build(:ticket_dependency, ticket: ticket_a, blocker: app_ticket)
      expect(dependency).to be_valid
    end

    it "impedisce il doppione sulla stessa coppia [ticket, blocker]" do
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      dup = build(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      expect(dup).not_to be_valid
      expect(dup.errors[:blocker_id]).to be_present
    end

    it "impedisce l'auto-dipendenza (A→A) con :not_self_dependency" do
      dependency = build(:ticket_dependency, ticket: ticket_a, blocker: ticket_a)
      expect(dependency).not_to be_valid
      expect(dependency.errors.added?(:blocker, :not_self_dependency)).to be true
    end

    it "impedisce la dipendenza cross-organizzazione con :same_organization" do
      foreign_ticket = create(:ticket, organization: create(:organization))
      dependency = build(:ticket_dependency, ticket: ticket_a, blocker: foreign_ticket)
      expect(dependency).not_to be_valid
      expect(dependency.errors.added?(:blocker, :same_organization)).to be true
    end
  end

  describe "anti-ciclo (validazione no_cycle)" do
    it "blocca il ciclo diretto A→B→A con :creates_cycle e non salva nulla" do
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      inverse = build(:ticket_dependency, ticket: ticket_b, blocker: ticket_a)

      expect(inverse).not_to be_valid
      expect(inverse.errors.added?(:base, :creates_cycle)).to be true
      expect do
        described_class.create(ticket: ticket_b, blocker: ticket_a, created_by: ticket_b.reporter)
      end.not_to change(described_class, :count)
    end

    it "blocca il ciclo transitivo A→B, B→C, poi C→A" do
      ticket_c = create(:ticket, organization:)
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      create(:ticket_dependency, ticket: ticket_b, blocker: ticket_c)

      closing = build(:ticket_dependency, ticket: ticket_c, blocker: ticket_a)
      expect(closing).not_to be_valid
      expect(closing.errors.added?(:base, :creates_cycle)).to be true
    end

    it "blocca il ciclo su una catena lunga A→B→C→D→E, poi E→A" do
      chain = [ ticket_a, ticket_b ] + Array.new(3) { create(:ticket, organization:) }
      chain.each_cons(2) { |dependent, blocker| create(:ticket_dependency, ticket: dependent, blocker:) }

      closing = build(:ticket_dependency, ticket: chain.last, blocker: chain.first)
      expect(closing).not_to be_valid
      expect(closing.errors.added?(:base, :creates_cycle)).to be true
    end

    it "lascia valido il diamante senza ciclo (A→B, A→C, B→D, C→D)" do
      ticket_c = create(:ticket, organization:)
      ticket_d = create(:ticket, organization:)
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_c)
      create(:ticket_dependency, ticket: ticket_b, blocker: ticket_d)

      expect(build(:ticket_dependency, ticket: ticket_c, blocker: ticket_d)).to be_valid
    end

    it "risolve il messaggio i18n di :creates_cycle (nessuna traduzione mancante)" do
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      inverse = build(:ticket_dependency, ticket: ticket_b, blocker: ticket_a)
      inverse.valid?
      expect(inverse.errors[:base]).to include(
        I18n.t("activerecord.errors.models.connections/ticket_dependency.attributes.base.creates_cycle")
      )
    end
  end

  describe "associazioni su Ticketing::Ticket" do
    it "espone dependencies/blockers dal lato dipendente e blocking/dependents dal lato blocker" do
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)

      expect(ticket_a.dependencies).to include(dependency)
      expect(ticket_a.blockers).to include(ticket_b)
      expect(ticket_b.blocking).to include(dependency)
      expect(ticket_b.dependents).to include(ticket_a)
    end
  end

  describe "#unmet_dependencies / #blocked? / #workable? (su Ticketing::Ticket)" do
    it "con zero dipendenze: non bloccato e lavorabile" do
      expect(ticket_a.unmet_dependencies).to be_empty
      expect(ticket_a.blocked?).to be false
      expect(ticket_a.workable?).to be true
    end

    it "con un blocker NON done: bloccato e non lavorabile" do
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      expect(ticket_a.unmet_dependencies).to be_present
      expect(ticket_a.blocked?).to be true
      expect(ticket_a.workable?).to be false
    end

    it "con l'unico blocker done: non più bloccato" do
      create(:ticket_dependency, ticket: ticket_a, blocker: done_ticket)
      expect(ticket_a.unmet_dependencies).to be_empty
      expect(ticket_a.blocked?).to be false
      expect(ticket_a.workable?).to be true
    end

    it "con N blocker misti: unmet_dependencies conta solo quelli non done" do
      open_blocker = ticket_b
      create(:ticket_dependency, ticket: ticket_a, blocker: open_blocker)
      create(:ticket_dependency, ticket: ticket_a, blocker: done_ticket)
      create(:ticket_dependency, ticket: ticket_a, blocker: done_ticket)

      expect(ticket_a.unmet_dependencies.count).to eq(1)
      expect(ticket_a.unmet_dependencies.first.blocker).to eq(open_blocker)
      expect(ticket_a.blocked?).to be true
    end

    it "unmet_dependencies è una relation (query, non filtro Ruby)" do
      expect(ticket_a.unmet_dependencies).to be_a(ActiveRecord::Relation)
    end

    it "workable? è definito anche per un ticket già done" do
      resolved = done_ticket
      expect(resolved.workable?).to be true

      create(:ticket_dependency, ticket: resolved, blocker: ticket_b)
      expect(resolved.blocked?).to be true
      expect(resolved.workable?).to be false
    end
  end

  describe "cancellazione (scenario 6)" do
    it "cade con il ticket dipendente (cascade)" do
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      expect { dependency.ticket.destroy! }.to change(described_class, :count).by(-1)
    end

    it "cade con il blocker (cascade)" do
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      expect { dependency.blocker.destroy! }.to change(described_class, :count).by(-1)
    end

    it "sopravvive alla cancellazione del creatore azzerando created_by_id (nullify)" do
      creator = create(:account)
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b, created_by: creator)

      expect { creator.destroy! }.not_to change(described_class, :count)
      expect(dependency.reload.created_by_id).to be_nil
    end
  end

  describe "immutabilità della topologia (ticket_id/blocker_id readonly)" do
    it "rifiuta il cambio di blocker in update: una dipendenza non si re-indirizza" do
      ticket_c = create(:ticket, organization:)
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)

      expect { dependency.update!(blocker: ticket_c) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(dependency.reload.blocker_id).to eq(ticket_b.id)
    end

    it "rifiuta il cambio di ticket dipendente in update" do
      ticket_c = create(:ticket, organization:)
      dependency = create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)

      expect { dependency.update!(ticket: ticket_c) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(dependency.reload.ticket_id).to eq(ticket_a.id)
    end

    it "un update non può introdurre un ciclo: la topologia è congelata dopo la create" do
      # A→B esiste; B→C esiste. Re-indirizzare B→C in B→A chiuderebbe il ciclo A→B→A: readonly lo blocca.
      ticket_c = create(:ticket, organization:)
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      b_to_c = create(:ticket_dependency, ticket: ticket_b, blocker: ticket_c)

      expect { b_to_c.update!(blocker: ticket_a) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(described_class.where(ticket_id: ticket_b.id, blocker_id: ticket_a.id)).to be_empty
    end
  end

  describe "difese DB-level (oltre le validazioni applicative)" do
    it "il CHECK constraint rifiuta l'auto-dipendenza anche bypassando validazione e callback" do
      # insert_all! salta validazioni E callback (il guard anti-ciclo tratterebbe già il self come
      # ciclo): così l'INSERT arriva al DB e a fermarlo resta solo il CHECK constraint.
      now = Time.current
      expect do
        described_class.insert_all!([ { ticket_id: ticket_a.id, blocker_id: ticket_a.id, created_at: now, updated_at: now } ])
      end.to raise_error(ActiveRecord::StatementInvalid, /check constraint/i)
    end

    it "l'unique index rifiuta il doppione [ticket, blocker] anche bypassando la validazione" do
      create(:ticket_dependency, ticket: ticket_a, blocker: ticket_b)
      expect do
        described_class.new(ticket: ticket_a, blocker: ticket_b).save!(validate: false)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
