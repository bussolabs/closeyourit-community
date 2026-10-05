# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Attachments::Upload do
  let(:page) { create(:knowledge_page) }
  let(:actor) { create(:account) }

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  it "crea un allegato per file, con title = filename originale e created_by = actor" do
    result = described_class.call(page: page,
                                  files: [ upload("screenshot.png", "image/png"),
                                           upload("notes.txt", "text/plain") ],
                                  actor: actor)

    expect(result).to be_ok
    expect(result.value.length).to eq(2)
    expect(page.attachments.count).to eq(2)
    expect(page.attachments.pluck(:title)).to contain_exactly("screenshot.png", "notes.txt")
    expect(page.attachments.map(&:created_by).uniq).to eq([ actor ])
    expect(page.attachments.all? { |a| a.file.attached? }).to be(true)
  end

  it "ritorna err R422-KNOWLEDGE-008 senza file" do
    result = described_class.call(page: page, files: [], actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-008")
  end

  describe "script (il motivo per cui questi allegati esistono)" do
    it "accetta uno script di shell" do
      result = described_class.call(page: page, files: [ upload("script.sh", "application/x-sh") ], actor: actor)

      expect(result).to be_ok
      expect(page.attachments.first.file.blob.content_type).to eq("application/x-sh")
    end

    it "accetta un sorgente Ruby SENZA shebang" do
      # Marcel sniffa lo stesso linguaggio in due tipi diversi a seconda dello shebang: se
      # l'allowlist coprisse solo application/x-sh, un file di libreria verrebbe rifiutato.
      result = described_class.call(page: page, files: [ upload("model.rb", "text/x-ruby") ], actor: actor)

      expect(result).to be_ok
      expect(page.attachments.first.file.blob.content_type).to eq("text/x-ruby")
    end

    it "accetta un archivio compresso" do
      result = described_class.call(page: page, files: [ upload("archive.tar.gz", "application/gzip") ], actor: actor)

      expect(result).to be_ok
    end
  end

  describe "file che il browser eseguirebbe da solo" do
    it "rifiuta una pagina web dichiarata onestamente" do
      result = described_class.call(page: page, files: [ upload("payload.html", "text/html") ], actor: actor)

      expect(result).to be_err
      expect(page.attachments.count).to eq(0)
    end

    it "rifiuta un'immagine vettoriale" do
      result = described_class.call(page: page, files: [ upload("diagram.svg", "image/svg+xml") ], actor: actor)

      expect(result).to be_err
      expect(page.attachments.count).to eq(0)
    end
  end

  describe "spoofing: il contenuto vince sul nome e sul tipo dichiarato" do
    it "rifiuta una pagina web travestita da immagine" do
      result = described_class.call(page: page, files: [ upload("payload.html", "image/png") ], actor: actor)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-KNOWLEDGE-008")
      expect(page.attachments.count).to eq(0)
    end

    it "rifiuta un'immagine vettoriale travestita da PNG" do
      result = described_class.call(page: page, files: [ upload("diagram.svg", "image/png") ], actor: actor)

      expect(result).to be_err
      expect(page.attachments.count).to eq(0)
    end
  end

  # Falla nota dello sniff, documentata perché la copre un ALTRO strato: un frammento HTML senza
  # doctype non ha magic byte, Marcel lo classifica text/plain e passa. Non è sfruttabile perché
  # text/plain non è renderizzabile inline (config/initializers/active_storage.rb): il browser lo
  # scarica invece di eseguirlo. Se un domani text/plain tornasse inline, questo spec resta verde ma
  # quello dell'initializer no — ed è lì che va guardato.
  it "accetta un frammento HTML senza doctype, che verrà comunque solo scaricato" do
    result = described_class.call(page: page, files: [ upload("fragment.txt", "text/plain") ], actor: actor)

    expect(result).to be_ok
    expect(page.attachments.first.file.blob.forced_disposition_for_serving).to eq(:attachment)
  end

  describe "all-or-nothing" do
    it "non crea nulla se anche un solo file del lotto è invalido" do
      result = described_class.call(page: page,
                                    files: [ upload("script.sh", "application/x-sh"),
                                             upload("payload.html", "text/html") ],
                                    actor: actor)

      expect(result).to be_err
      expect(page.attachments.count).to eq(0)
    end
  end
end
