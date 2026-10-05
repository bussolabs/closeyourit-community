# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Attachment do
  describe ".allowed_file?" do
    it "ammette i documenti già ammessi altrove" do
      expect(described_class.allowed_file?(content_type: "application/pdf", byte_size: 1.megabyte)).to be(true)
    end

    it "ammette uno script di shell" do
      expect(described_class.allowed_file?(content_type: "application/x-sh", byte_size: 2.kilobytes)).to be(true)
    end

    it "ammette un sorgente Ruby senza shebang" do
      # Marcel sniffa .rb CON shebang come application/x-sh e SENZA come text/x-ruby: se l'allowlist
      # ne coprisse solo una forma, metà degli script verrebbe rifiutata senza una ragione visibile.
      expect(described_class.allowed_file?(content_type: "text/x-ruby", byte_size: 2.kilobytes)).to be(true)
    end

    it "rifiuta una pagina web" do
      expect(described_class.allowed_file?(content_type: "text/html", byte_size: 1.kilobyte)).to be(false)
    end

    it "rifiuta un'immagine vettoriale" do
      expect(described_class.allowed_file?(content_type: "image/svg+xml", byte_size: 1.kilobyte)).to be(false)
    end

    it "rifiuta il tipo di fallback dell'ignoto" do
      # application/octet-stream è ciò che Marcel ritorna quando non riconosce nulla (es. un
      # Dockerfile o un binario qualsiasi): ammetterlo svuoterebbe di senso l'allowlist.
      expect(described_class.allowed_file?(content_type: "application/octet-stream", byte_size: 1.kilobyte)).to be(false)
    end

    it "rifiuta un file oltre il limite di dimensione" do
      oltre = Knowledge::Constants::ATTACHMENT_MAX_SIZE + 1
      expect(described_class.allowed_file?(content_type: "application/pdf", byte_size: oltre)).to be(false)
    end
  end

  describe "validazioni" do
    it "è valido con titolo e file ammesso" do
      expect(build(:knowledge_attachment)).to be_valid
    end

    it "richiede un titolo" do
      attachment = build(:knowledge_attachment, title: "")

      expect(attachment).not_to be_valid
      expect(attachment.errors[:title]).to be_present
    end

    it "richiede un file" do
      attachment = build(:knowledge_attachment)
      attachment.file.detach

      expect(attachment).not_to be_valid
      expect(attachment.errors[:file]).to be_present
    end

    it "rifiuta un file di tipo non ammesso" do
      attachment = build(:knowledge_attachment)
      attachment.file.attach(
        io: StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"),
        filename: "evil.svg", content_type: "image/svg+xml"
      )

      expect(attachment).not_to be_valid
      expect(attachment.errors[:file]).to be_present
    end

    it "rifiuta un file oltre il limite" do
      # Il blob va persistito prima di poterne falsificare la dimensione (update_column non gira su
      # un record nuovo); stesso trucco di spec/models/concerns/attachable_spec.rb.
      attachment = create(:knowledge_attachment)
      attachment.file.blob.update_column(:byte_size, Knowledge::Constants::ATTACHMENT_MAX_SIZE + 1)

      expect(attachment.reload).not_to be_valid
      expect(attachment.errors[:file]).to be_present
    end
  end

  describe "normalizzazione" do
    it "toglie gli spazi attorno al titolo" do
      expect(build(:knowledge_attachment, title: "  Script di deploy  ").tap(&:valid?).title)
        .to eq("Script di deploy")
    end

    it "riduce a nil una descrizione vuota" do
      expect(build(:knowledge_attachment, description: "   ").tap(&:valid?).description).to be_nil
    end
  end

  describe "#sanitized_filename" do
    def filename_for(nome)
      attachment = build(:knowledge_attachment)
      attachment.file.attach(io: StringIO.new("ciao"), filename: nome, content_type: "text/plain")
      attachment.sanitized_filename
    end

    it "conserva un nome già pulito" do
      expect(filename_for("deploy.sh")).to eq("deploy.sh")
    end

    it "non lascia passare i separatori di percorso" do
      # Coperto da ActiveStorage::Filename#sanitized, che li sostituisce con "-": qui verifichiamo
      # l'esito che ci interessa (nessun separatore nel nome consegnato), non chi lo produce.
      expect(filename_for("../../etc/passwd")).not_to include("/")
      expect(filename_for("cartella\\file.sh")).not_to include("\\")
    end

    it "elimina i caratteri di controllo che ActiveStorage non tocca" do
      # Il tr di ActiveStorage copre solo \t \r \n; un vertical-tab o un \x01 passerebbero e
      # spezzerebbero l'header Content-Disposition.
      expect(filename_for("deploy\v\x01.sh")).to eq("deploy.sh")
    end

    it "il null byte non arriva nemmeno al metodo: lo respinge ActiveStorage" do
      # Documentato come test perche' e' una difesa che NON ci appartiene e potrebbe cambiare: se un
      # domani l'attach lo accettasse, questo esempio fallisce e ci ricorda di gestirlo noi.
      attachment = build(:knowledge_attachment)

      expect do
        attachment.file.attach(io: StringIO.new("ciao"), filename: "deploy\0.sh", content_type: "text/plain")
      end.to raise_error(ArgumentError, /null byte/)
    end

    it "non lascia passare l'override RTL" do
      # ‮ inverte la resa del testo: "exe‮gnp.sh" appare come "exehs.png" e convince
      # l'utente di stare salvando un'immagine invece di uno script. Lo neutralizza già ActiveStorage.
      expect(filename_for("exe‮gnp.sh")).not_to include("‮")
    end

    it "elimina gli altri marcatori bidirezionali, che ActiveStorage non tocca" do
      # Il tr di ActiveStorage cita il solo ‮: LRE/RLE/PDF/LRO e gli isolate ⁦-⁩
      # producono lo stesso inganno visivo e passerebbero indisturbati.
      %W[‪ ‫ ‭ ⁦ ⁩].each do |marcatore|
        expect(filename_for("exe#{marcatore}gnp.sh")).not_to include(marcatore)
      end
    end

    it "non resta mai vuoto" do
      expect(filename_for("///")).to be_present
    end
  end

  describe "associazioni" do
    it "muore insieme alla propria pagina" do
      attachment = create(:knowledge_attachment)

      expect { attachment.page.destroy }.to change(described_class, :count).by(-1)
    end

    it "sopravvive alla cancellazione di chi l'ha caricato" do
      account = create(:account)
      attachment = create(:knowledge_attachment, created_by: account)

      account.destroy

      expect(attachment.reload.created_by_id).to be_nil
    end
  end

  describe "ordinamento" do
    it "elenca per posizione e poi per data di creazione" do
      page = create(:knowledge_page)
      secondo = create(:knowledge_attachment, page: page, position: 1)
      primo = create(:knowledge_attachment, page: page, position: 0)

      expect(page.attachments.ordered).to eq([ primo, secondo ])
    end
  end

  # Gli allegati sono STORAGE, non contenuto della pagina. Se un domani finissero nel testo di
  # embedding o nelle versioni, la ricerca semantica indicizzerebbe binari e la cronologia
  # proverebbe a "ripristinare" dei file: entrambe regressioni silenziose, che qui restano visibili.
  describe "confini con il resto del dominio Knowledge" do
    let(:page) { create(:knowledge_page) }

    it "non cambia il testo indicizzato per la ricerca semantica" do
      prima = Knowledge::EmbeddingText.call(page: page)

      create(:knowledge_attachment, :script, page: page)

      expect(Knowledge::EmbeddingText.call(page: page.reload)).to eq(prima)
    end

    it "non cambia il checksum dell'embedding" do
      prima = Knowledge::EmbeddingText.checksum(page: page)

      create(:knowledge_attachment, :script, page: page)

      expect(Knowledge::EmbeddingText.checksum(page: page.reload)).to eq(prima)
    end

    it "non viene toccato dal ripristino di una versione precedente" do
      Knowledge::UpdatePage.call(page: page, params: { body: "Corpo aggiornato." }, actor: page.created_by)
      attachment = create(:knowledge_attachment, page: page)

      Knowledge::RestoreVersion.call(page: page, version: page.versions.first, actor: page.created_by)

      expect(page.reload.attachments).to eq([ attachment ])
    end
  end
end
