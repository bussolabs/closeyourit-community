# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Documents::Upload do
  let(:project) { create(:project) }
  let(:actor) { create(:account) }

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  it "crea un documento per file, con title = filename originale e created_by = actor" do
    result = described_class.call(project: project,
                                  files: [ upload("screenshot.png", "image/png"),
                                           upload("notes.txt", "text/plain") ],
                                  actor: actor)

    expect(result).to be_ok
    expect(result.value.length).to eq(2)
    expect(project.documents.count).to eq(2)
    expect(project.documents.pluck(:title)).to contain_exactly("screenshot.png", "notes.txt")
    expect(project.documents.map(&:created_by).uniq).to eq([ actor ])
    expect(project.documents.all? { |d| d.file.attached? }).to be(true)
  end

  it "registra un evento 'created' per ogni documento caricato" do
    expect do
      result = described_class.call(project: project, files: [ upload("screenshot.png", "image/png") ], actor: actor)
      expect(result).to be_ok

      event = result.value.first.activity_events.last
      expect(event.action).to eq("created")
      expect(event.organization_id).to eq(project.organization_id)
    end.to change(Activity::Event, :count).by(1)
  end

  describe "metadati dichiarati insieme al file (canale CLI)" do
    it "applica title, description e tag senza aggiungere un evento 'updated'" do
      result = described_class.call(project: project, files: [ upload("notes.txt", "text/plain") ],
                                    attributes: { title: "Verbale", description: "Riunione", tags: %w[Legal legal] },
                                    actor: actor)

      expect(result).to be_ok
      document = result.value.sole
      expect(document.title).to eq("Verbale")
      expect(document.description).to eq("Riunione")
      expect(document.tags).to eq([ "legal" ])
      expect(document.activity_events.pluck(:action)).to eq([ "created" ])
    end

    it "su un lotto ignora il title esplicito: ogni file tiene il proprio nome" do
      result = described_class.call(project: project,
                                    files: [ upload("screenshot.png", "image/png"),
                                             upload("notes.txt", "text/plain") ],
                                    attributes: { title: "Unico", tags: [ "lotto" ] },
                                    actor: actor)

      expect(result).to be_ok
      expect(result.value.map(&:title)).to contain_exactly("screenshot.png", "notes.txt")
      expect(result.value.map(&:tags).uniq).to eq([ [ "lotto" ] ])
    end
  end

  it "ritorna err R422-DOCUMENT-001 senza file" do
    result = described_class.call(project: project, files: [], actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-DOCUMENT-001")
  end

  it "rifiuta un parametro che non è affatto un file, senza sollevare" do
    result = described_class.call(project: project, files: [ "notes.txt" ], actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-DOCUMENT-001")
    expect(project.documents.count).to eq(0)
  end

  it "rifiuta un tipo non ammesso dichiarato onestamente" do
    result = described_class.call(project: project,
                                  files: [ upload("diagram.svg", "image/svg+xml") ], actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-DOCUMENT-001")
    expect(project.documents.count).to eq(0)
  end

  it "rifiuta un content-type spoofato (svg dichiarato image/png) via sniff server-side" do
    result = described_class.call(project: project,
                                  files: [ upload("diagram.svg", "image/png") ], actor: actor)

    expect(result).to be_err
    expect(project.documents.count).to eq(0)
  end

  it "rifiuta file oltre DOCUMENT_MAX_SIZE" do
    stub_const("App::Constants::DOCUMENT_MAX_SIZE", 10)
    result = described_class.call(project: project,
                                  files: [ upload("screenshot.png", "image/png") ], actor: actor)

    expect(result).to be_err
    expect(project.documents.count).to eq(0)
  end

  it "batch all-or-nothing: un file invalido nel lotto → zero documenti" do
    result = described_class.call(project: project,
                                  files: [ upload("screenshot.png", "image/png"),
                                           upload("diagram.svg", "image/svg+xml") ],
                                  actor: actor)

    expect(result).to be_err
    expect(project.documents.count).to eq(0)
  end
end
