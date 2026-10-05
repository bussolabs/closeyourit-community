require "rails_helper"

RSpec.describe Ticketing::Report, type: :model do
  let(:report_max) { Ticketing::Constants::REPORT_MAX_CHARS }
  # Un ticket e un autore che gli appartiene davvero: il resoconto valida il tenant come i commenti,
  # quindi l'autore va costruito nell'organizzazione del ticket, non in una qualsiasi.
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }

  def report(**attributes)
    build(:ticket_report, organization: organization, ticket: ticket, **attributes)
  end

  it "produce un resoconto valido" do
    expect(build(:ticket_report)).to be_valid
  end

  describe "numerazione delle versioni" do
    it "assegna 1 al primo resoconto del ticket e poi numeri crescenti" do
      expect(report.tap(&:save!).version).to eq(1)
      expect(report.tap(&:save!).version).to eq(2)
      expect(report.tap(&:save!).version).to eq(3)
    end

    it "numera in modo indipendente su ticket diversi" do
      other = create(:ticket, organization: organization)
      report.save!

      expect(report(ticket: other).tap(&:save!).version).to eq(1)
    end

    it "rifiuta due versioni con lo stesso numero sullo stesso ticket" do
      report.save!

      duplicate = report(version: 1)

      expect(duplicate).to be_invalid
      expect(duplicate.errors[:version]).to be_present
    end

    it "rispetta il numero passato esplicitamente (lo usa la migrazione dati)" do
      expect(report(version: 7).tap(&:save!).version).to eq(7)
      expect(report.tap(&:save!).version).to eq(8)
    end

    it "usa il numero come parametro di URL" do
      expect(build(:ticket_report, version: 3).to_param).to eq("3")
    end
  end

  describe "immutabilità (append-only)" do
    it "ignora la riscrittura del corpo di una versione già scritta" do
      report = create(:ticket_report, body: "Originale.")

      expect { report.update!(body: "Riscritto.") }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  describe "corpo" do
    it "è invalido se vuoto o di soli spazi" do
      expect(build(:ticket_report, body: nil)).to be_invalid
      expect(build(:ticket_report, body: "   ")).to be_invalid
    end

    it "normalizza gli spazi ai bordi" do
      expect(create(:ticket_report, body: "  Fatto.  ").body).to eq("Fatto.")
    end

    it "mette gli accenti mancanti" do
      report = create(:ticket_report, body: "Il fix e' gia in produzione, non serve piu' altro")

      expect(report.body).to eq("Il fix è già in produzione, non serve più altro")
    end

    it "conta i fine-riga come li conta il browser (CRLF normalizzato a LF)" do
      report = create(:ticket_report, body: "x#{"\r\n" * 10}y")

      expect(report.body).not_to include("\r")
    end

    it "accetta un corpo esattamente al limite e rifiuta quello oltre" do
      expect(build(:ticket_report, body: "x" * report_max)).to be_valid

      too_long = build(:ticket_report, body: "x" * (report_max + 1))
      expect(too_long).to be_invalid
      expect(too_long.errors.details[:body])
        .to include(hash_including(error: :length_budget_exceeded, count: report_max))
    end
  end

  describe "integrità tenant (l'autore appartiene all'organizzazione del ticket)" do
    it "è invalido se l'autore non è membro dell'org del ticket" do
      organization = create(:organization)
      ticket = create(:ticket, organization: organization)
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization), role: :member)

      report = build(:ticket_report, ticket: ticket, author: outsider)

      expect(report).to be_invalid
      expect(report.errors[:author]).to be_present
    end

    it "accetta un resoconto senza autore (account cancellato)" do
      expect(build(:ticket_report, author: nil)).to be_valid
    end
  end

  describe "origine" do
    it "nasce manuale e accetta agent e migrated" do
      expect(build(:ticket_report)).to be_source_manual
      expect(build(:ticket_report, source: :agent)).to be_source_agent
      expect(build(:ticket_report, source: :migrated)).to be_source_migrated
    end

    it "non ammette due versioni dallo stesso commento di origine" do
      comment = create(:ticket_comment, organization: organization, ticket: ticket)
      report(source: :migrated, source_comment: comment).save!

      # version esplicita: aggirando le validazioni salta anche assign_version, e senza numero
      # inciamperebbe nel NOT NULL invece che nell'indice che questo test vuole dimostrare.
      duplicate = report(source: :migrated, source_comment: comment, version: 2)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "associazione al ticket" do
    it "viene eliminato insieme al suo ticket" do
      persisted = report.tap(&:save!)

      expect { persisted.ticket.destroy }.to change(described_class, :count).by(-1)
    end

    it "il ticket espone la versione più alta come resoconto corrente" do
      report(body: "Prima.").save!
      last = report(body: "Seconda.").tap(&:save!)

      expect(ticket.reload.current_report).to eq(last)
      expect(ticket.reports.chronological.map(&:version)).to eq([ 1, 2 ])
    end
  end

  # CYRA-389 — la motivazione lunga di un respingimento è una versione del resoconto, perché il
  # resoconto è il posto del testo lungo di un ticket. Ma NON è il racconto di un lavoro consegnato:
  # dove il prodotto mostra "cosa è stato consegnato" (la coda Approvazioni) mostrarla vorrebbe dire
  # far leggere a chi decide la propria motivazione di prima come se fosse il lavoro di adesso.
  describe "versioni scritte respingendo un lavoro" do
    it "sono l'ultima stesura del resoconto come tutte le altre" do
      report(body: "Fatto, con i test.").save!
      respinta = report(body: "Manca il caso limite.", source: :review_rejection).tap(&:save!)

      expect(ticket.reload.current_report).to eq(respinta)
      expect(respinta).to be_source_review_rejection
    end

    it "non passano per resoconto del lavoro consegnato" do
      lavoro = report(body: "Fatto, con i test.").tap(&:save!)
      report(body: "Manca il caso limite.", source: :review_rejection).save!

      expect(described_class.delivered.map(&:id)).to eq([ lavoro.id ])
      expect(ticket.reload.current_work_report).to eq(lavoro)
    end

    it "senza nessuna stesura del lavoro il resoconto consegnato non esiste" do
      report(body: "Manca il caso limite.", source: :review_rejection).save!

      expect(ticket.reload.current_work_report).to be_nil
    end
  end
end
