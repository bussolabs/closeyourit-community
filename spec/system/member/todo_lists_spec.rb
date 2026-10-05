# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member — Todo lists", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:account) { create(:account) }

  before { create(:membership, account:, organization: org, role: :member) }

  def sign_in_as(who)
    visit login_path
    fill_test "login-email", with: who.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "dalla sidebar crea una lista, aggiunge una voce, la spunta e la elimina" do
    sign_in_as(account)

    click_on_test "member-nav-todos"
    expect(page).to have_current_path(member_todo_lists_path)

    click_on_test "todo-lists-new"
    fill_test "todo-list-name", with: "Sprint 12"
    click_on_test "todo-list-submit"
    expect_test "member-todo-list"

    list = Todos::List.find_by!(name: "Sprint 12", account:, organization: org)

    fill_test "todo-item-title-input", with: "Scrivere i test"
    click_on_test "todo-item-submit"

    item = list.items.find_by!(title: "Scrivere i test")
    expect(item.done?).to be(false)
    within_test("todo-list-stats") { expect(page).to have_text(I18n.t("member.todo_lists.progress_header", done: 0, total: 1)) }

    # CYRA-828 — anche per navigazione ordinaria (niente aggiornamento parziale qui) la spunta e il
    # numero delle completate devono raccontare la stessa cosa, all'andata e al ritorno.
    click_on_test "todo-item-toggle-#{item.id}"
    expect(item.reload.done?).to be(true)
    within_test("todo-list-stats") { expect(page).to have_text(I18n.t("member.todo_lists.progress_header", done: 1, total: 1)) }

    # A done item sits in the Completed group, closed until opened.
    find("[data-test='todo-items-done'] summary").click
    click_on_test "todo-item-toggle-#{item.id}"
    expect(item.reload.done?).to be(false)
    within_test("todo-list-stats") { expect(page).to have_text(I18n.t("member.todo_lists.progress_header", done: 0, total: 1)) }

    click_on_test "todo-item-delete-#{item.id}"
    expect(Todos::Item.exists?(item.id)).to be(false)
  end

  it "una lista condivisa con me compare in 'Condivise con me' senza controlli di modifica" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :member)
    shared = create(:todo_list, account: owner, organization: org, name: "Piano owner")
    create(:todo_share, list: shared, account:)

    sign_in_as(account)
    visit member_todo_lists_path
    expect_test "todo-lists-count-lists"
    expect_test "todo-lists-count-shared"
    expect_test "todo-lists-shared"
    expect(page).to have_text("Piano owner")

    visit member_todo_list_path(shared)
    expect_test "member-todo-list"
    expect(page).to have_no_css("[data-test='todo-item-form']")
  end
end
