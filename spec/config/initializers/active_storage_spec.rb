# frozen_string_literal: true

require "rails_helper"

# Barriera 4 di CYRA-176: nessun file caricato deve poter essere renderizzato o eseguito dal browser.
# La posture vive in config/initializers/active_storage.rb; questi test la bloccano contro le due
# regressioni realistiche — che le liste divergano da App::Constants, e che un upgrade di Rails
# cambi l'ordine di boot o allarghi i default sotto di noi.
RSpec.describe "postura di serving di ActiveStorage" do
  describe "tipi serviti come binario (Content-Type application/octet-stream)" do
    it "copre TUTTI i tipi script ammessi come allegato di una pagina KB" do
      scoperti = Knowledge::Constants::SCRIPT_CONTENT_TYPES -
                 ActiveStorage.content_types_to_serve_as_binary

      expect(scoperti).to be_empty,
                          "questi tipi sarebbero serviti col loro Content-Type reale invece che come " \
                          "binario: #{scoperti.join(', ')}. Allineare la lista letterale in " \
                          "config/initializers/active_storage.rb a Knowledge::Constants::SCRIPT_CONTENT_TYPES."
    end

    it "conserva i tipi pericolosi che ActiveStorage neutralizza di serie" do
      # Estendiamo il default, non lo sostituiamo: perderli riaprirebbe lo stored XSS che
      # DOCUMENT_CONTENT_TYPES e ICON_IMAGE_CONTENT_TYPES evitano a monte.
      expect(ActiveStorage.content_types_to_serve_as_binary)
        .to include("text/html", "image/svg+xml", "application/xhtml+xml", "text/xml", "application/xml")
    end
  end

  describe "tipi renderizzabili inline" do
    it "ammette solo immagini raster, PDF e i video degli allegati" do
      expect(ActiveStorage.content_types_allowed_inline).to contain_exactly(
        "image/webp", "image/avif", "image/png", "image/gif",
        "image/jpeg", "image/tiff", "image/bmp", "application/pdf",
        *App::Constants::VIDEO_CONTENT_TYPES
      )
    end

    it "copre TUTTI i tipi video ammessi come allegato (altrimenti il lettore nel ticket non parte)" do
      scoperti = App::Constants::VIDEO_CONTENT_TYPES - ActiveStorage.content_types_allowed_inline
      expect(scoperti).to be_empty, "video serviti forced-download, il tag <video> non li riproduce: #{scoperti.join(', ')}"
    end

    it "non ammette inline il testo semplice" do
      # Non è pedanteria: un FRAMMENTO html senza doctype (`<img src=x onerror=...>`) non ha magic
      # byte, Marcel lo sniffa text/plain anche se il file si chiama .html, e text/plain è
      # nell'allowlist degli allegati. Questa riga è ciò che impedisce al browser di eseguirlo.
      expect(ActiveStorage.content_types_allowed_inline).not_to include("text/plain")
    end

    it "non ammette inline alcuno script della knowledge base" do
      ammessi_per_errore = Knowledge::Constants::SCRIPT_CONTENT_TYPES &
                           ActiveStorage.content_types_allowed_inline

      expect(ammessi_per_errore).to be_empty
    end
  end

  describe "effetto sul blob servito" do
    it "forza il download di uno script invece di mostrarlo" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("#!/bin/bash\necho ciao\n"),
        filename: "deploy.sh",
        content_type: "application/x-sh"
      )

      expect(blob.content_type_for_serving).to eq("application/octet-stream")
      expect(blob.forced_disposition_for_serving).to eq(:attachment)
    end

    it "forza il download anche di un frammento HTML travestito da testo" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("<img src=x onerror=alert(1)>"),
        filename: "innocuo.txt",
        content_type: "text/plain"
      )

      expect(blob.forced_disposition_for_serving).to eq(:attachment)
    end

    it "lascia invece visibile inline un'immagine" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
        filename: "screenshot.png",
        content_type: "image/png"
      )

      expect(blob.content_type_for_serving).to eq("image/png")
      expect(blob.forced_disposition_for_serving).to be_nil
    end
  end
end
