# frozen_string_literal: true

require "rails_helper"

# CYRA-163 — "Il mio lavoro": i ticket assegnati all'account corrente, in tutti i progetti visibili
# dell'organizzazione, su un'unica pagina. Riusa Member::TicketsController#list (già org-wide) con un
# filtro assignee_id di default sull'account corrente, raggiunto da una nuova voce di navigazione.
RSpec.describe "Member tickets — Il mio lavoro", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "mostra i ticket assegnati all'account in progetti diversi, e solo quelli" do
    account = admin_account
    project_a = create(:project, organization: org, name: "Storefront", key: "STR")
    project_b = create(:project, organization: org, name: "Backoffice", key: "BO")
    mine_a = create(:ticket, organization: org, project: project_a, status: status, priority: priority,
                    assignee: account, title: "Fix checkout")
    mine_b = create(:ticket, organization: org, project: project_b, status: status, priority: priority,
                    assignee: account, title: "Fix invoices")
    other = create(:ticket, organization: org, project: project_a, status: status, priority: priority,
                    title: "Not mine")

    sign_in_as(account)
    # La voce vive nella verticale Application (Navigation::Space): dopo il login si atterra sulla Home,
    # che non ha sidebar. Stessa premessa degli altri system spec di quello space (ideas_spec).
    visit member_application_path
    expect_test "member-nav-my-work"
    click_on_test "member-nav-my-work"

    expect(page).to have_css("[data-test='ticket-row']", count: 2)
    expect(page).to have_text(mine_a.title)
    expect(page).to have_text(mine_b.title)
    expect(page).to have_no_text(other.title)
  end

  it "senza ticket assegnati mostra lo stato vuoto, senza errori" do
    account = admin_account
    project = create(:project, organization: org, name: "Storefront", key: "STR")
    create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(account)
    visit member_application_path
    click_on_test "member-nav-my-work"

    # "Il mio lavoro" è la lista con un filtro assignee_id sempre acceso: zero risultati con un filtro
    # attivo è `tickets-no-results` (CYRA-387), non `tickets-empty` — che significa "non esiste alcun
    # ticket" e qui direbbe il falso.
    expect_test "tickets-no-results"
  end
end
