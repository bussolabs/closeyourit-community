# frozen_string_literal: true

require "rails_helper"

# The Documents tab list: upload in the search bar, drop on the list, sortable columns and
# richer rows. CYRA-883
RSpec.describe "Member::ProjectDocuments list", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:reader) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: reader, organization: org, role: :member)
    create(:project_membership, account: reader, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def file(name, content_type, bytes: 10)
    { io: StringIO.new("x" * bytes), filename: name, content_type: content_type }
  end

  def row_order(*documents)
    documents.sort_by { |document| response.body.index("document-row-#{document.id}") }
  end

  def test_node(test_id)
    Nokogiri::HTML(response.body).at_css("[data-test='#{test_id}']")
  end

  # CYRA-924 — the bar holds only search, filters and View (C63, T5): the count and the upload button
  # sit in the section title, and the bar lives inside the list panel.
  describe "section title" do
    it "holds the count and the upload button for a manager, with no upload block above the list" do
      # Bulk fixture: the factory attaches per record; the index itself preloads the files.
      allow_n_plus_one { create_list(:document, 2, project: project) }
      sign_in(owner)
      get member_project_documents_path(project)

      heading = test_node("documents-heading")
      expect(heading.at_css("[data-test='documents-count']").text).to include("2 documents")
      expect(heading.at_css("[data-test='document-upload-button']")).to be_present
      expect(heading.at_css("[data-test='document-upload-form']")).to be_present
      expect(test_node("document-dropzone")).to be_nil
    end

    it "shows the count but no upload button to a reader" do
      create(:document, project: project)
      sign_in(reader)
      get member_project_documents_path(project)

      expect(test_node("documents-heading").text).to include("1 document")
      expect(test_node("document-upload-button")).to be_nil
      expect(test_node("document-upload-form")).to be_nil
    end

    it "keeps the count and the upload button out of the bar, which sits inside the list panel" do
      create(:document, project: project)
      sign_in(owner)
      get member_project_documents_path(project)

      toolbar = test_node("documents-list").at_css("[data-test='documents-toolbar']")
      expect(toolbar).to be_present
      expect(toolbar.text).not_to include("1 document")
      expect(toolbar.at_css("[data-test='document-upload-button']")).to be_nil
    end
  end

  describe "drop on the list" do
    it "makes the table the drop target for a manager" do
      create(:document, project: project)
      sign_in(owner)
      get member_project_documents_path(project)

      actions = test_node("documents-list")["data-action"]
      expect(actions).to include("drop->attachment-upload#drop", "dragover->attachment-upload#dragover")
    end

    it "is not a drop target for a reader" do
      create(:document, project: project)
      sign_in(reader)
      get member_project_documents_path(project)

      expect(test_node("documents-list")["data-action"]).to be_nil
    end
  end

  describe "empty state" do
    it "explains, gives an example and offers the drop area and the upload button to a manager" do
      sign_in(owner)
      get member_project_documents_path(project)

      empty = test_node("documents-empty")
      expect(empty.text).to include(I18n.t("member.documents.empty"), I18n.t("member.documents.empty_example"))
      expect(test_node("document-dropzone")).to be_present
      expect(test_node("documents-empty-upload")).to be_present
    end

    it "shows no example and no upload to a reader" do
      sign_in(reader)
      get member_project_documents_path(project)

      expect(test_node("documents-empty").text).not_to include(I18n.t("member.documents.empty_example"))
      expect(test_node("document-dropzone")).to be_nil
      expect(test_node("documents-empty-upload")).to be_nil
    end
  end

  describe "sorting" do
    before { sign_in(owner) }

    it "sorts by title, case-insensitive, both ways" do
      banana = create(:document, project: project, title: "banana")
      apple = create(:document, project: project, title: "Apple")
      cherry = create(:document, project: project, title: "cherry")

      get member_project_documents_path(project), params: { sort: "title" }
      expect(row_order(banana, apple, cherry)).to eq([ apple, banana, cherry ])

      get member_project_documents_path(project), params: { sort: "-title" }
      expect(row_order(banana, apple, cherry)).to eq([ cherry, banana, apple ])
    end

    it "sorts by size and by type" do
      small = create(:document, project: project, file: file("small.txt", "text/plain", bytes: 5))
      large = create(:document, project: project, file: file("large.pdf", "application/pdf", bytes: 500))
      mid = create(:document, project: project, file: file("mid.png", "image/png", bytes: 50))

      get member_project_documents_path(project), params: { sort: "-size" }
      expect(row_order(small, large, mid)).to eq([ large, mid, small ])

      get member_project_documents_path(project), params: { sort: "type" }
      expect(row_order(small, large, mid)).to eq([ large, mid, small ])
    end

    it "sorts by upload date, newest first on desc" do
      old = create(:document, project: project, created_at: 3.days.ago)
      recent = create(:document, project: project, created_at: 1.hour.ago)

      get member_project_documents_path(project), params: { sort: "-uploaded" }
      expect(row_order(old, recent)).to eq([ recent, old ])

      get member_project_documents_path(project), params: { sort: "uploaded" }
      expect(row_order(old, recent)).to eq([ old, recent ])
    end

    it "renders sortable headers that open size and date largest or newest first" do
      create(:document, project: project)
      get member_project_documents_path(project)

      %w[title type].each { |key| expect(response.body).to include("sort=#{key}") }
      %w[size uploaded].each { |key| expect(response.body).to include("sort=-#{key}") }
    end
  end

  describe "rows" do
    before { sign_in(owner) }

    it "shows the description under the file name and finds it in search" do
      described = create(:document, project: project, description: "Signed by the customer")
      other = create(:document, project: project)

      get member_project_documents_path(project), params: { q: "customer" }
      expect(test_node("document-description-#{described.id}").text).to eq("Signed by the customer")
      expect(response.body).not_to include("document-row-#{other.id}")
    end

    it "downloads the file from the title" do
      document = create(:document, project: project)
      get member_project_documents_path(project)

      expect(test_node("document-title-link-#{document.id}")["href"]).to include("disposition=attachment")
    end

    it "offers Open in a new tab for PDFs and images only" do
      pdf = create(:document, project: project)
      image = create(:document, project: project, file: file("shot.png", "image/png"))
      text = create(:document, project: project, file: file("notes.txt", "text/plain"))
      get member_project_documents_path(project)

      [ pdf, image ].each do |document|
        link = test_node("document-open-#{document.id}")
        expect(link["href"]).to include("disposition=inline")
        expect(link["target"]).to eq("_blank")
      end
      expect(test_node("document-open-#{text.id}")).to be_nil
    end

    it "links each tag to the list filtered on it" do
      document = create(:document, project: project, tags: %w[legal])
      get member_project_documents_path(project)

      href = test_node("document-tag-#{document.id}-legal")["href"]
      expect(href).to eq(member_project_documents_path(project, tag: [ "legal" ]))
    end

    it "marks each row with an icon for its file type" do
      document = create(:document, project: project)
      get member_project_documents_path(project)

      icon = test_node("document-icon-#{document.id}")
      expect(icon["data-icon"]).to eq("file-text")
      expect(icon["class"]).to include("text-red-500")
    end
  end

  describe "type labels" do
    it "translates images and text files into Italian" do
      create(:document, project: project, file: file("shot.png", "image/png"))
      create(:document, project: project, file: file("notes.txt", "text/plain"))
      owner.update!(locale: "it")
      sign_in(owner)
      get member_project_documents_path(project)

      expect(response.body).to include(">Immagine<", ">Testo<")
      expect(response.body).not_to include(">Image<", ">Text<")
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      document = create(:document, project: project, title: "Contratto")

      get member_project_documents_path(project)

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='document-delete-dialog-#{document.id}']")
      expect(dialog.text).to include(I18n.t("member.documents.delete_dialog.title", title: "Contratto"))
      expect(dialog.at_css("form")["action"]).to eq(member_project_document_path(project, document))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='document-delete-#{document.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
