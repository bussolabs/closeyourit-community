# frozen_string_literal: true

require "rails_helper"

# CYRA-882 — knowledge pages linked only to moved projects or groups move with them; the others stay.
RSpec.describe "Projects::Moves knowledge pages" do
  let(:owner) { create(:account) }
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:project) { create(:project, organization: source) }
  let(:other) { create(:project, organization: source) }
  let(:move) { create(:project_move, subject: project, destination_organization: destination, requested_by: owner) }

  before do
    create(:membership, account: owner, organization: source, role: :owner)
    create(:membership, account: owner, organization: destination, role: :owner)
  end

  def execute = Projects::Moves::Execute.call(move:)
  def plan = Projects::Moves::Plan.call(subject: Projects::Moves::Subject.new(project), destination:).value

  def book_linked_to(*projects, title: "Runbooks")
    book = create(:knowledge_book, organization: source, project: projects.first, title:)
    projects.drop(1).each { book.projects << _1 }
    book
  end

  it "moves a page linked only to a moved project, with its versions and attachments" do
    page = create(:knowledge_page, project:)
    version = create(:knowledge_version, page:, organization: source)
    attachment = create(:knowledge_attachment, page:)

    expect(execute).to be_ok

    expect(page.reload.organization_id).to eq(destination.id)
    expect(page.projects).to eq([ project ])
    expect(version.reload.organization_id).to eq(destination.id)
    expect(destination.knowledge_pages.find(page.id).attachments.first.file.download).to eq("%PDF-1.4 fake")
    expect(attachment.reload.page_id).to eq(page.id)
  end

  it "moves a page linked to a moved group and to its projects" do
    group = create(:group, organization: source)
    project.update!(group:)
    page = create(:knowledge_page, project:)
    page.groups << group
    group_move = create(:project_move, subject: group, destination_organization: destination, requested_by: owner)

    expect(Projects::Moves::Execute.call(move: group_move)).to be_ok

    expect(page.reload.organization_id).to eq(destination.id)
    expect([ page.projects, page.groups ]).to eq([ [ project ], [ group ] ])
  end

  it "keeps a mixed page in the source and removes only its link to the moved project" do
    page = create(:knowledge_page, project:)
    page.projects << other

    expect(plan.detachments).to include({ table: "connections_page_projects", count: 1 })
    expect(execute).to be_ok

    expect(page.reload.organization_id).to eq(source.id)
    expect(page.projects).to eq([ other ])
  end

  it "does not touch a page without project or group links" do
    page = create(:knowledge_page, :org_wide, organization: source)

    expect(execute).to be_ok

    expect(page.reload.organization_id).to eq(source.id)
  end

  it "moves a whole book linked only to moved projects whose pages all move" do
    book = book_linked_to(project)
    page = create(:knowledge_page, project:, book:)

    expect(plan.creations).to include({ table: "knowledge_pages", count: 1 },
                                      { table: "knowledge_books", title: "Runbooks", outcome: "moves", books: 1 })
    expect(execute).to be_ok

    expect(book.reload.organization_id).to eq(destination.id)
    expect(book.projects).to eq([ project ])
    expect(page.reload.book_id).to eq(book.id)
  end

  it "points a moved page to the destination book with the same title" do
    book = book_linked_to(project, other)
    page = create(:knowledge_page, project:, book:)
    target = create(:knowledge_book, organization: destination, title: "Runbooks")

    expect(plan.creations).to include({ table: "knowledge_books", title: "Runbooks", outcome: "joined", books: 1 })
    expect(execute).to be_ok

    expect(page.reload.book_id).to eq(target.id)
    expect(book.reload.organization_id).to eq(source.id)
    expect(book.projects).to eq([ other ])
  end

  it "creates the destination book when no book there has the same title" do
    book = book_linked_to(project, other)
    page = create(:knowledge_page, project:, book:)

    expect(plan.creations).to include({ table: "knowledge_books", title: "Runbooks", outcome: "created", books: 1 })
    expect(execute).to be_ok

    created = page.reload.book
    expect([ created.organization_id, created.title, created.created_by_id ]).to eq([ destination.id, "Runbooks", owner.id ])
    expect(created.projects).to eq([ project ])
    expect(book.reload.organization_id).to eq(source.id)
  end

  it "deletes a page link that would cross organizations and keeps one between moved pages" do
    moved = create(:knowledge_page, project:)
    sibling = create(:knowledge_page, project:)
    staying = create(:knowledge_page, project: other)
    create(:page_link, page: moved, related: staying)
    create(:page_link, page: staying, related: moved)
    kept = create(:page_link, page: moved, related: sibling)

    expect(plan.detachments).to include({ table: "connections_page_links", count: 2 })
    expect(execute).to be_ok

    expect(Connections::PageLink.pluck(:id)).to eq([ kept.id ])
  end

  it "blocks on a publication key the destination already uses and changes nothing" do
    page = create(:knowledge_page, project:, publication_key: "deploy-guide")
    create(:knowledge_page, organization: destination, publication_key: "deploy-guide")

    expect(plan.blockers).to include({ code: "knowledge_publication_conflict", detail: "deploy-guide" })
    expect(execute).to be_err

    expect(page.reload.organization_id).to eq(source.id)
    expect(project.reload.organization_id).to eq(source.id)
  end

  it "keeps the page of a sample question when the page moves and clears it when the page stays" do
    moved = create(:knowledge_page, project:)
    mixed = create(:knowledge_page, project:)
    mixed.projects << other
    kept = create(:knowledge_sample_question, project:, knowledge_page: moved)
    cleared = create(:knowledge_sample_question, project:, knowledge_page: mixed)

    expect(execute).to be_ok

    expect(kept.reload.knowledge_page_id).to eq(moved.id)
    expect(cleared.reload.knowledge_page_id).to be_nil
  end

  describe "a book that stays and would lose every link" do
    let(:third) { create(:project, organization: source) }

    it "links it to the projects of its staying pages before the moved links go" do
      book = book_linked_to(project)
      moved = create(:knowledge_page, project:, book:)
      staying = create(:knowledge_page, project:, book:)
      staying.projects << other

      expect(plan.detachments).to include({ table: "knowledge_books", count: 1 })
      expect(execute).to be_ok

      expect(book.reload.organization_id).to eq(source.id)
      expect(book.projects).to eq([ other ])
      expect(book).to be_valid
      expect(moved.reload.book.organization_id).to eq(destination.id)
    end

    it "does not relink a book that keeps a link to a staying project" do
      book = book_linked_to(project, other)
      create(:knowledge_page, project:, book:).projects << third

      expect(execute).to be_ok

      expect(book.reload.projects).to eq([ other ])
    end

    it "blocks when its staying pages have no project or group to link it to" do
      book = book_linked_to(project)
      create(:knowledge_page, project:, book:)
      create(:knowledge_page, :org_wide, organization: source, book:)

      expect(plan.blockers).to include({ code: "knowledge_book_orphaned", detail: "Runbooks" })
      expect(execute).to be_err

      expect(book.reload.projects).to eq([ project ])
    end
  end

  describe "the preview of the books of moved pages" do
    it "says the pages of a staying book join a moved book with the same title" do
      moving = book_linked_to(project)
      create(:knowledge_page, project:, book: moving)
      staying = book_linked_to(project, other)
      page = create(:knowledge_page, project:, book: staying)

      expect(plan.creations).to include({ table: "knowledge_books", title: "Runbooks", outcome: "joined", books: 1 })
      expect(plan.creations.pluck(:outcome)).not_to include("created")
      expect(execute).to be_ok

      expect(page.reload.book_id).to eq(moving.id)
    end

    it "says two staying books with the same title become one in the destination" do
      pages = [ book_linked_to(project, other), book_linked_to(project, other) ].map { create(:knowledge_page, project:, book: _1) }

      expect(plan.creations).to include({ table: "knowledge_books", title: "Runbooks", outcome: "created", books: 2 })
      expect(execute).to be_ok

      expect(pages.map { _1.reload.book_id }.uniq.size).to eq(1)
    end
  end

  it "locks the moving pages inside the move" do
    create(:knowledge_page, project:)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { execute }

    expect(queries).to include(a_string_matching(/FROM "knowledge_pages".*FOR UPDATE/m))
  end
end
