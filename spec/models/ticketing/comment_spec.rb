require "rails_helper"

RSpec.describe Ticketing::Comment, type: :model do
  it "produce un commento valido" do
    expect(build(:ticket_comment)).to be_valid
  end

  describe "body" do
    it "è invalido se vuoto o di soli spazi" do
      expect(build(:ticket_comment, body: nil)).not_to be_valid
      expect(build(:ticket_comment, body: "   ")).not_to be_valid
    end

    it "normalizza (strip) gli spazi" do
      comment = create(:ticket_comment, body: "  hello  ")
      expect(comment.body).to eq("hello")
    end

    it "mette gli accenti mancanti" do
      comment = create(:ticket_comment, body: "Se ne e' accorto, da li' non se ne vanno piu'")

      expect(comment.body).to eq("Se ne è accorto, da lì non se ne vanno più")
    end
  end

  describe "tetto di lunghezza" do
    let(:max) { Ticketing::Constants::COMMENT_MAX_CHARS }

    # Commento storico già oltre il tetto, come le righe scritte prima che esistesse.
    def legacy_long_comment
      build(:ticket_comment, body: "x" * (max + 500)).tap { |record| record.save!(validate: false) }
    end

    it "accetta un commento esattamente al limite" do
      expect(build(:ticket_comment, body: "x" * max)).to be_valid
    end

    it "rifiuta un commento oltre il limite e dice di quanto ha sforato" do
      comment = build(:ticket_comment, body: "x" * (max + 1))

      expect(comment).to be_invalid
      expect(comment.errors.details[:body])
        .to include(hash_including(error: :length_budget_exceeded, count: max, actual: max + 1))
    end

    it "conta i fine-riga come li conta il browser (CRLF normalizzato a LF)" do
      comment = build(:ticket_comment, body: "x#{"\r\n" * 50}".ljust(max + 50, "y"))

      expect(comment).to be_valid
      expect(comment.body.length).to eq(max)
      expect(comment.body).not_to include("\r")
    end

    it "non intrappola un commento storico che si accorcia o non cambia" do
      comment = legacy_long_comment

      comment.body = "x" * (comment.body.length - 100)
      expect(comment).to be_valid

      expect(comment.reload).to be_valid
    end

    it "blocca un commento storico che cresce ancora" do
      comment = legacy_long_comment
      comment.body = "#{comment.body}ancora testo"

      expect(comment).to be_invalid
      expect(comment.errors.details[:body]).to include(hash_including(error: :length_budget_exceeded))
    end
  end

  describe "kind (persona o riga di servizio)" do
    it "nasce human" do
      expect(build(:ticket_comment)).to be_kind_human
    end

    it "considera generata dall'automazione una riga di servizio" do
      expect(build(:ticket_comment, kind: :service)).to be_automation_generated
    end

    it "considera generata dall'automazione anche una riga legacy col marker nel corpo" do
      legacy = build(:ticket_comment, body: "Testo. <!-- closeyourit-automation:triage -->")

      expect(legacy).to be_kind_human
      expect(legacy).to be_automation_generated
    end

    it "non considera generato dall'automazione un commento di una persona" do
      expect(build(:ticket_comment)).not_to be_automation_generated
    end
  end

  describe "#automated? (segnale di rendering: attore automatico, non una persona)" do
    it "è automatico quando l'autore è un service account (agente o host)" do
      org = create(:organization)
      ticket = create(:ticket, organization: org)
      agent = create(:account, :service)
      create(:membership, account: agent, organization: org, role: :member)

      expect(build(:ticket_comment, ticket: ticket, author: agent)).to be_automated
    end

    it "è automatico per una riga di servizio e per una riga legacy col marker" do
      expect(build(:ticket_comment, kind: :service)).to be_automated
      expect(build(:ticket_comment, body: "Testo. <!-- closeyourit-automation:triage -->")).to be_automated
    end

    it "non è automatico per un commento scritto da una persona" do
      expect(build(:ticket_comment)).not_to be_automated
    end
  end

  describe "integrità tenant (l'autore appartiene all'organizzazione del ticket)" do
    it "è invalido se l'autore non è membro dell'org" do
      org = create(:organization)
      ticket = create(:ticket, organization: org)
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization), role: :member)

      comment = build(:ticket_comment, ticket: ticket, author: outsider)

      expect(comment).not_to be_valid
      expect(comment.errors[:author]).to be_present
    end

    it "è valido se l'autore è membro dell'org" do
      org = create(:organization)
      ticket = create(:ticket, organization: org)
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)

      expect(build(:ticket_comment, ticket: ticket, author: member)).to be_valid
    end

    it "salta il controllo tenant se manca il ticket o l'autore (nil-safe)" do
      expect(build(:ticket_comment, ticket: nil)).not_to be_valid
      expect(build(:ticket_comment, author: nil)).not_to be_valid
    end
  end

  describe "associazione al ticket" do
    it "viene eliminato insieme al suo ticket" do
      comment = create(:ticket_comment)

      expect { comment.ticket.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe "allegati (Attachable)" do
    it "accetta un tipo di file ammesso entro il limite di dimensione" do
      comment = build(:ticket_comment)
      comment.files.attach(io: StringIO.new("x"), filename: "a.png", content_type: "image/png")

      expect(comment).to be_valid
    end

    it "rifiuta un content type non ammesso" do
      comment = build(:ticket_comment)
      comment.files.attach(io: StringIO.new("x"), filename: "a.zip", content_type: "application/zip")

      expect(comment).not_to be_valid
      expect(comment.errors[:files]).to be_present
    end

    it "accetta un file esattamente al limite di dimensione (confine)" do
      comment = build(:ticket_comment)
      comment.files.attach(
        io: StringIO.new("a" * App::Constants::ATTACHMENT_MAX_SIZE),
        filename: "max.txt", content_type: "text/plain"
      )

      expect(comment).to be_valid
    end

    it "rifiuta un file oltre il limite di dimensione" do
      comment = build(:ticket_comment)
      comment.files.attach(
        io: StringIO.new("a" * (App::Constants::ATTACHMENT_MAX_SIZE + 1)),
        filename: "big.png", content_type: "image/png"
      )

      expect(comment).not_to be_valid
      expect(comment.errors[:files]).to be_present
    end
  end
end
