# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Attachments", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: admin, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "admin allega un file valido al ticket" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(ticket.reload.files).to be_attached
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "membro non-manager → negato, nessun allegato" do
      sign_in(member)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to redirect_to(root_path)
    end

    it "tipo non ammesso → rifiutato, nessun allegato" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("diagram.svg", "image/svg+xml") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "senza file → nessun allegato, redirect con alert" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {}
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "content-type spoofato (svg dichiarato image/png) → rifiutato (sniff server-side)" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("diagram.svg", "image/png") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      sign_in(admin)
      foreign = create(:ticket, organization: create(:organization))
      post member_ticket_attachments_path(foreign), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "admin rimuove un allegato del ticket" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      sign_in(admin)
      expect do
        delete member_ticket_attachment_path(ticket, attachment)
      end.to change { ticket.reload.files.count }.by(-1)
    end

    it "membro non-manager non può rimuovere allegati del ticket" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      sign_in(member)
      delete member_ticket_attachment_path(ticket, attachment)
      expect(ticket.reload.files).to be_attached
    end
  end

  # CYRA-1121 — i file del ticket e dei commenti si aprono SOLO dalla rotta del ticket, che ricontrolla
  # la visibilità a ogni richiesta; le rotte generiche /rails/active_storage/ non li servono più.
  describe "apertura dei file (CYRA-1121)" do
    let(:png) { File.binread(file_fixture("screenshot.png")) }
    let(:video_bytes) { "0123456789abcdefghij" * 5 }

    def attach_screenshot(record)
      record.files.attach(io: StringIO.new(png), filename: "screenshot.png", content_type: "image/png")
      record.files_attachments.order(:created_at).last
    end

    def attach_video(record)
      record.files.attach(io: StringIO.new(video_bytes), filename: "clip.mp4", content_type: "video/mp4",
                          identify: false)
      record.files_attachments.order(:created_at).last
    end

    def revoke(account)
      Connections::ProjectMembership.where(account: account, project: project).destroy_all
    end

    def received?(bytes)
      response.body.b.include?(bytes.b)
    end

    # Tutte le varianti generiche: redirect (anche la forma storica senza /redirect), proxy e
    # rappresentazioni. Se un aggiornamento di Rails salta il controllo, queste prove falliscono.
    def legacy_paths(blob)
      key = ActiveStorage::Variation.encode(resize_to_limit: [ 10, 10 ])
      base = "/rails/active_storage"
      [
        "#{base}/blobs/redirect/#{blob.signed_id}/#{blob.filename}",
        "#{base}/blobs/#{blob.signed_id}/#{blob.filename}",
        "#{base}/blobs/proxy/#{blob.signed_id}/#{blob.filename}",
        "#{base}/representations/redirect/#{blob.signed_id}/#{key}/#{blob.filename}",
        "#{base}/representations/#{blob.signed_id}/#{key}/#{blob.filename}",
        "#{base}/representations/proxy/#{blob.signed_id}/#{key}/#{blob.filename}"
      ]
    end

    describe "GET file (rotta protetta)" do
      it "chi vede il ticket apre immagine e download; il tipo inline rispetta l'initializer" do
        file = attach_screenshot(ticket)
        sign_in(member)

        get member_ticket_file_path(ticket, file)
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(png.b)
        expect(response.media_type).to eq("image/png")
        expect(response.headers["Content-Disposition"]).to start_with("inline")
        expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")

        get member_ticket_file_path(ticket, file, disposition: :attachment)
        expect(response.headers["Content-Disposition"]).to start_with("attachment")
      end

      it "un tipo non mostrabile inline (testo) esce sempre come download" do
        ticket.files.attach(io: StringIO.new("<img src=x onerror=alert(1)>"), filename: "note.txt",
                            content_type: "text/plain", identify: false)
        sign_in(member)

        get member_ticket_file_path(ticket, ticket.files_attachments.last)

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to start_with("attachment")
      end

      it "il file di un commento si apre dalla rotta del suo ticket" do
        comment = create(:ticket_comment, ticket: ticket, organization: org)
        file = attach_screenshot(comment)
        sign_in(member)

        get member_ticket_file_path(ticket, file)

        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(png.b)
      end

      it "il browser deve ricontrollare prima di riusare la copia, e ogni ricontrollo ripassa dalla visibilità" do
        file = attach_screenshot(ticket)
        sign_in(member)

        get member_ticket_file_path(ticket, file)
        etag = response.headers["ETag"]
        expect(response.headers["Cache-Control"]).to include("no-cache")
        expect(etag).to be_present

        get member_ticket_file_path(ticket, file), headers: { "If-None-Match" => etag }
        expect(response).to have_http_status(:not_modified)

        revoke(member)
        get member_ticket_file_path(ticket, file), headers: { "If-None-Match" => etag }
        expect(response).to have_http_status(:not_found)
      end

      it "SC-2: il nuovo indirizzo del file di un commento non si apre più dopo la revoca" do
        comment = create(:ticket_comment, ticket: ticket, organization: org)
        file = attach_screenshot(comment)
        sign_in(member)
        get member_ticket_file_path(ticket, file)
        expect(response).to have_http_status(:ok)

        revoke(member)
        get member_ticket_file_path(ticket, file)

        expect(response).to have_http_status(:not_found)
        expect(received?(png)).to be(false)
      end

      it "SC-3/SC-4: il video si serve a pezzi, e ogni pezzo ricontrolla l'accesso" do
        file = attach_video(ticket)
        sign_in(member)

        get member_ticket_file_path(ticket, file), headers: { "Range" => "bytes=10-19" }
        expect(response).to have_http_status(:partial_content)
        expect(response.body).to eq(video_bytes[10..19])
        expect(response.headers["Content-Range"]).to eq("bytes 10-19/#{video_bytes.bytesize}")
        expect(response.headers["Accept-Ranges"]).to eq("bytes")
        expect(response.headers["Content-Disposition"]).to start_with("inline")

        get member_ticket_file_path(ticket, file), headers: { "Range" => "bytes=5000-" }
        expect(response).to have_http_status(:range_not_satisfiable)

        revoke(member)
        get member_ticket_file_path(ticket, file), headers: { "Range" => "bytes=20-29" }
        expect(response).to have_http_status(:not_found)
        expect(received?(video_bytes[20..29])).to be(false)
      end

      it "SC-8: un file del ticket B chiesto dall'indirizzo del ticket A → 404" do
        other_project = create(:project, organization: org)
        other_ticket = create(:ticket, organization: org, project: other_project)
        file = attach_screenshot(other_ticket)
        sign_in(member)

        get member_ticket_file_path(ticket, file)
        expect(response).to have_http_status(:not_found)

        get member_ticket_file_path(other_ticket, file)
        expect(response).to have_http_status(:not_found)
        expect(received?(png)).to be(false)
      end

      it "senza accesso effettuato → pagina di accesso, nessun byte" do
        file = attach_screenshot(ticket)

        get member_ticket_file_path(ticket, file)

        expect(response).to redirect_to(login_path)
        expect(received?(png)).to be(false)
      end
    end

    describe "vecchi link /rails/active_storage/" do
      it "SC-5: chi vede ancora il ticket viene portato alla rotta protetta e vede il file" do
        file = attach_screenshot(ticket)
        sign_in(member)

        # Una richiesta per variante dalla stessa riga: prosopite la conterebbe come N+1 di produzione.
        allow_n_plus_one do
          legacy_paths(file.blob).each do |path|
            get path
            expect(response).to redirect_to(member_ticket_file_path(ticket, file)), path
          end
        end

        get rails_blob_path(file, disposition: :attachment)
        expect(response).to redirect_to(member_ticket_file_path(ticket, file, disposition: "attachment"))
        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(png.b)
      end

      it "SC-1: tolto dal progetto, il vecchio link dello screenshot non invia nessun byte" do
        file = attach_screenshot(ticket)
        old_link = rails_blob_path(file, disposition: :inline)
        sign_in(member)
        revoke(member)

        get old_link
        expect(received?(png)).to be(false)
        follow_redirect!
        expect(response).to have_http_status(:not_found)
        expect(received?(png)).to be(false)

        allow_n_plus_one do
          legacy_paths(file.blob).each do |path|
            get path
            expect(response).to redirect_to(member_ticket_file_path(ticket, file)), path
            expect(response.location).not_to include("/rails/active_storage/disk/"), path
            expect(received?(png)).to be(false), path
          end
        end
      end

      it "il vecchio link del file di un commento porta alla rotta del ticket" do
        comment = create(:ticket_comment, ticket: ticket, organization: org)
        file = attach_screenshot(comment)
        sign_in(member)

        get rails_blob_path(file)

        expect(response).to redirect_to(member_ticket_file_path(ticket, file))
      end

      it "SC-6: non collegato → pagina di accesso, il file non parte mai" do
        file = attach_screenshot(ticket)

        allow_n_plus_one do
          legacy_paths(file.blob).each do |path|
            get path
            expect(received?(png)).to be(false), path
            follow_redirect!
            expect(response).to redirect_to(login_path), path
            expect(received?(png)).to be(false), path
          end
        end
      end

      it "i file di domande e risposte non escono più: 404 su ogni variante" do
        question = create(:ticket_question, ticket: ticket, organization: org)
        answer = create(:ticket_answer, question: question, organization: org)
        # Setup: un allegato per scheda, prosopite conterebbe i due attach come N+1 di produzione.
        files = allow_n_plus_one { [ attach_screenshot(question), attach_screenshot(answer) ] }
        sign_in(admin)

        allow_n_plus_one do
          files.each do |file|
            legacy_paths(file.blob).each do |path|
              get path
              expect(response).to have_http_status(:not_found), path
              expect(received?(png)).to be(false), path
            end
          end
        end
      end

      it "allegato rimosso, binario ancora in attesa del purge: il vecchio link non serve il file" do
        file = attach_screenshot(ticket)
        blob = file.blob
        # Come la rimozione standard: l'aggancio sparisce subito, il blob resta fino a purge_later
        # (o per sempre, se il job fallisce).
        file.delete
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)

        allow_n_plus_one do
          legacy_paths(blob).each do |path|
            get path
            expect(response).to have_http_status(:not_found), path
            expect(received?(png)).to be(false), path
          end

          sign_in(member)
          legacy_paths(blob).each do |path|
            get path
            expect(response).to have_http_status(:not_found), path
            expect(received?(png)).to be(false), path
          end
        end
      end

      it "SC-9: icona e documenti di progetto restano serviti come oggi" do
        project.icon_image.attach(io: StringIO.new(png), filename: "icon.png", content_type: "image/png")
        document = create(:document, project: project)
        sign_in(member)

        get rails_blob_path(project.icon_image, disposition: :inline)
        expect(response.location).to include("/rails/active_storage/disk/")

        get rails_storage_proxy_path(project.icon_image)
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(png.b)

        get rails_blob_path(document.file, disposition: :attachment)
        expect(response.location).to include("/rails/active_storage/disk/")
      end
    end

    it "la pagina del ticket non contiene link generici per i file di ticket e commenti" do
      attach_screenshot(ticket)
      attach_video(ticket)
      comment = create(:ticket_comment, ticket: ticket, organization: org)
      attach_screenshot(comment)
      sign_in(member)

      get member_ticket_path(ticket)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/rails/active_storage/")
      ticket.files_attachments.each do |file|
        expect(response.body).to include(member_ticket_file_path(ticket, file))
        expect(response.body).to include(member_ticket_file_path(ticket, file, disposition: :attachment)) if file.video?
      end

      get member_ticket_path(ticket, tab: "discussion")
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/rails/active_storage/")
      expect(response.body).to include(member_ticket_file_path(ticket, comment.files_attachments.first))
    end
  end
end
