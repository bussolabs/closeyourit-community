# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket GitHub", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization: org))
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account:, organization: org, role: :owner)
    account
  end

  it "mostra il bottone e crea il branch dal ticket" do
    allow(Github::Client).to receive(:new)
      .and_return(instance_double(Github::Client, ref: { "object" => { "sha" => "abc" } }, create_ref: {}))
    sign_in_as(owner_account)

    visit member_ticket_path(ticket)
    # CYRA-402: i comandi rivolti a chi sviluppa stanno sotto la voce «Sviluppo»; l'icona del ramo
    # la distingue dai «...» delle altre azioni, che le stanno accanto.
    expect(page).to have_css("[data-test='ticket-dev-menu'] svg[data-icon='git-branch']")
    click_on_test "ticket-dev-menu"
    expect_test "ticket-github-branch"
    click_on_test "ticket-github-branch"

    expect(ticket.github_branches).to exist
    expect_test "ticket-github-panel"
  end

  it "il pannello elenca branch e PR collegati" do
    create(:github_branch, repository:, ticket:, name: "#{ticket.code}-fix")
    create(:github_pull_request, repository:, ticket:, number: 4)
    sign_in_as(owner_account)

    visit member_ticket_path(ticket)

    expect_test "ticket-github-panel"
    expect_test "ticket-github-branch-row"
    expect_test "ticket-github-pr-row"
  end
end
