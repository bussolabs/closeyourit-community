# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Knowledge::Attachments", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:altro_membro) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:page) { create(:knowledge_page, organization: org, project: project, created_by: member) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: altro_membro, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: altro_membro, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  describe "POST create" do
    it "l'autore della pagina carica più file insieme" do
      sign_in(member)

      expect do
        # Upload batch: una risoluzione attachment per allegato CREATO (insert per-record di
        # ActiveStorage) — lineare per natura, non un N+1 di lettura riducibile con preload.
        # Stessa esenzione motivata di spec/requests/member/project_documents_spec.rb.
        allow_n_plus_one do
          post member_knowledge_page_attachments_path(page),
               params: { files: [ upload("script.sh", "application/x-sh"), upload("notes.txt", "text/plain") ] }
        end
      end.to change(Knowledge::Attachment, :count).by(2)

      expect(response).to redirect_to(member_knowledge_page_path(page))
      expect(page.attachments.pluck(:title)).to contain_exactly("script.sh", "notes.txt")
    end

    it "rifiuta una pagina web con un messaggio, senza creare nulla" do
      sign_in(member)

      expect do
        post member_knowledge_page_attachments_path(page), params: { files: [ upload("payload.html", "text/html") ] }
      end.not_to change(Knowledge::Attachment, :count)

      expect(flash[:alert]).to be_present
    end

    it "rifiuta un file travestito, fidandosi del contenuto e non del tipo dichiarato" do
      sign_in(member)

      expect do
        post member_knowledge_page_attachments_path(page), params: { files: [ upload("payload.html", "image/png") ] }
      end.not_to change(Knowledge::Attachment, :count)
    end

    it "nega a un membro che non è l'autore e non ha knowledge.edit" do
      sign_in(altro_membro)

      expect do
        post member_knowledge_page_attachments_path(page), params: { files: [ upload("notes.txt", "text/plain") ] }
      end.not_to change(Knowledge::Attachment, :count)

      expect(response).to redirect_to(member_knowledge_page_path(page))
      expect(flash[:alert]).to be_present
    end

    it "consente a un owner di allegare a una pagina altrui" do
      sign_in(owner)

      expect do
        post member_knowledge_page_attachments_path(page), params: { files: [ upload("notes.txt", "text/plain") ] }
      end.to change(Knowledge::Attachment, :count).by(1)
    end

    it "risponde 404 su una pagina di un progetto non visibile" do
      estranea = create(:knowledge_page, organization: org, project: create(:project, organization: org))
      sign_in(member)

      post member_knowledge_page_attachments_path(estranea), params: { files: [ upload("notes.txt", "text/plain") ] }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET download" do
    let!(:attachment) do
      Knowledge::Attachments::Upload.call(page: page, files: [ upload("script.sh", "application/x-sh") ],
                                          actor: member).value.first
    end

    it "consegna il file a chi vede la pagina, forzandone il download" do
      sign_in(altro_membro) # non autore: il download NON è gated

      get download_member_knowledge_page_attachment_path(page, attachment)

      expect(response).to have_http_status(:ok)
      # Mai il tipo reale (application/x-sh): il browser non deve avere alcun appiglio per aprirlo.
      expect(response.headers["Content-Type"]).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to start_with("attachment")
      expect(response.headers["Content-Disposition"]).to include("script.sh")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.body).to include("echo")
    end

    it "risponde 404 per un allegato di un'altra pagina" do
      altra_pagina = create(:knowledge_page, organization: org, project: project, created_by: member)
      sign_in(member)

      get download_member_knowledge_page_attachment_path(altra_pagina, attachment)

      expect(response).to have_http_status(:not_found)
    end

    # Il nome del file NON entra nel path della rotta proprio per questo: le blocklist scanner di
    # rack-attack respingono i path che finiscono in .php/.cgi, e un allegato legittimo così chiamato
    # riceverebbe un 404 muto prima ancora di arrivare al controller.
    it "consegna anche un allegato chiamato install.php" do
      php = Knowledge::Attachments::Upload.call(page: page, files: [ upload("script.sh", "application/x-sh") ],
                                                 actor: member).value.first
      php.file.blob.update!(filename: "install.php")
      sign_in(member)

      Rack::Attack.enabled = true
      get download_member_knowledge_page_attachment_path(page, php)
      Rack::Attack.enabled = false

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to eq("Not Found")
      expect(response.headers["Content-Disposition"]).to include("install.php")
    end
  end

  describe "PATCH update (rinomina)" do
    let!(:attachment) { create(:knowledge_attachment, page: page, created_by: member) }

    it "l'autore rinomina il proprio allegato" do
      sign_in(member)

      patch member_knowledge_page_attachment_path(page, attachment),
            params: { title: "Procedura di rilascio", description: "Da eseguire a mano" }

      expect(attachment.reload.title).to eq("Procedura di rilascio")
      expect(attachment.description).to eq("Da eseguire a mano")
    end

    it "nega a chi non può modificare la pagina" do
      sign_in(altro_membro)

      patch member_knowledge_page_attachment_path(page, attachment), params: { title: "Cambiato" }

      expect(attachment.reload.title).not_to eq("Cambiato")
    end
  end

  describe "DELETE destroy" do
    let!(:attachment) { create(:knowledge_attachment, page: page, created_by: member) }

    it "l'autore elimina il proprio allegato" do
      sign_in(member)

      expect do
        delete member_knowledge_page_attachment_path(page, attachment)
      end.to change(Knowledge::Attachment, :count).by(-1)
    end

    it "nega a chi non può modificare la pagina" do
      sign_in(altro_membro)

      expect do
        delete member_knowledge_page_attachment_path(page, attachment)
      end.not_to change(Knowledge::Attachment, :count)
    end
  end
end
