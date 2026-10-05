# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket discussion", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account, name: "Olivia Lane") }
  let(:member) { create(:account, name: "Marco Rossi") }
  let(:customer) { create(:account, name: "Dana Kim") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: customer, project: project)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "un membro aggiunge un commento" do
    ticket
    sign_in_as(member)
    visit member_ticket_path(ticket, tab: "discussion")

    fill_test "member-ticket-comment-body", with: "Confermo il bug"
    click_on_test "member-ticket-comment-submit"

    expect_test "flash-notice"
    expect(ticket.comments.reload.map(&:body)).to include("Confermo il bug")
    expect(ticket.comments.last.author).to eq(member)
  end

  it "un customer può commentare" do
    ticket
    sign_in_as(customer)
    visit member_ticket_path(ticket, tab: "discussion")

    fill_test "member-ticket-comment-body", with: "Succede anche a me"
    click_on_test "member-ticket-comment-submit"

    expect(ticket.comments.reload.last.author).to eq(customer)
  end

  it "un owner allega un file al ticket dalla pagina show" do
    ticket
    sign_in_as(owner)
    # Gli allegati del TICKET stanno nel dettaglio; nella discussione si allega ai commenti (CYRA-219).
    visit member_ticket_path(ticket)
    click_on_test "member-ticket-attachments-open" # CYRA-883: with no files the drop area opens on click

    attach_file "member-ticket-attachment-input",
                Rails.root.join("spec/fixtures/files/screenshot.png").to_s
    click_on_test "member-ticket-attachment-submit"

    expect(ticket.reload.files).to be_attached
  end

  it "l'autore vede il delete del proprio commento, non di quello altrui" do
    own = create(:ticket_comment, ticket: ticket, author: member, body: "mio")
    other = create(:ticket_comment, ticket: ticket, author: owner, body: "altrui")

    sign_in_as(member)
    visit member_ticket_path(ticket, tab: "discussion")

    expect(page).to have_css("[data-test='member-ticket-comment-delete-#{own.id}']")
    expect(page).to have_no_css("[data-test='member-ticket-comment-delete-#{other.id}']")
  end

  it "la timeline unifica commenti ed eventi di sistema in un'unica lista" do
    comment = create(:ticket_comment, ticket: ticket, author: member, body: "commento utente")
    Ticketing::ChangeStatus.call(channel: :web,
      organization: org, ticket: ticket,
      status_id: create(:ticket_status, organization: org).id, actor: owner
    )
    event = Ticketing::Event.last

    sign_in_as(owner)
    visit member_ticket_path(ticket, tab: "discussion")

    within_test "member-ticket-comments" do
      expect(page).to have_css("[data-test='member-ticket-comment-#{comment.id}']")
      expect(page).to have_css("[data-test='member-ticket-event-#{event.id}']")
    end
  end
end
