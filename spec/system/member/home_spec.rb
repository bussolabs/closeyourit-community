# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member home", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "dice che non aspetta niente quando non c'è nulla da decidere" do
    sign_in_as(owner)

    expect(page).to have_current_path(root_path)
    expect_test "home-empty-done"
  end

  # CYRA-658 — qui c'erano i quattro riquadri del feed. Adesso la pagina mostra UNA decisione, con
  # il progetto a sinistra e i pulsanti a destra.
  it "mostra una decisione sola, col progetto e con le azioni" do
    project = create(:project, organization: org)
    org.update_column(:cto_id, owner.id)
    ticket = create(:ticket, organization: org, project:,
                             title: "Ricerca coi caratteri strani")
    create(:agent_workflow, ticket:, planned_at: 2.days.ago)

    sign_in_as(owner)

    expect(page).to have_content(ticket.code)
    expect_test "decision-columns"
    expect_test "decision-project"
    expect_test "approvals-decision"
    expect_test "decision-not-now"
  end

  # CYRA-504 chiedeva il via libera alla produzione dalla pagina iniziale, e finché non si premeva la
  # produzione non partiva. CYRA-629 ha tolto quella fermata: conclusa la prova di staging il
  # rilascio parte da solo, e la pagina iniziale non chiede più niente.
  #
  # L'assenza si prova con qualcosa accanto: il feed deve avere DENTRO un'altra riga, o una pagina
  # vuota per un motivo qualsiasi passerebbe lo stesso.
  it "conclusa la prova di staging la pagina iniziale non chiede più niente" do
    project = create(:project, organization: org)
    org.update_column(:cto_id, owner.id)
    ticket = create(:ticket, organization: org, project:,
                             title: "Pronta per la produzione")
    workflow = create(:agent_workflow, :closer_staging_completed, ticket:)
    create(:agent_attempt, workflow:, organization: org, phase: "closer_staging", status: :approved,
                           result: { "state" => "staging-released", "tag" => "v1.4.0-beta.1", "commit" => "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" })
    da_approvare = create(:ticket, organization: org, project:,
                                   title: "Questa invece aspetta me")
    create(:agent_workflow, ticket: da_approvare, triaged_at: 1.day.ago, planned_at: Time.current)

    sign_in_as(owner)

    # La decisione mostrata è quella che aspetta davvero; il rilascio non chiede più niente.
    expect(page).to have_content(da_approvare.code)
    expect(page).to have_no_content(ticket.code)

    # Nessuno ha premuto, e il rilascio è comunque in coda.
    expect(workflow.reload.ready_execution_phase).to eq("closer_production")
    expect(workflow.closer_production_approved_at).to be_nil
  end

  # CYRA-630 — qui c'erano le decisioni della riga: due pulsanti icon-only e il motivo del rifiuto in
  # un <dialog>. Erano una delle CINQUE porte da cui si prendeva la stessa decisione, e ognuna con la
  # sua regola. Adesso la riga non decide: porta alla scheda, che è l'unico posto in cui si decide.
  describe "dal feed si arriva alla scheda, e si decide lì" do
    let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
    let!(:in_review) { create(:ticket_status, :in_review, organization: org, code: "in_review", position: 2) }
    let!(:ticket) { create(:ticket, organization: org, project:, status: in_review, reviewer: owner) }

    it "la riga non porta nessun pulsante di decisione" do
      sign_in_as(owner)

      # La riga c'è — l'assenza dei pulsanti è un'assenza, non una pagina vuota.
      expect(page).to have_content(ticket.code)
      expect(page).to have_no_css("[data-test='home-decision']", visible: :all)
      expect(page).to have_no_css("[data-test='home-approve']", visible: :all)
      expect(page).to have_no_css("[data-test='home-reject']", visible: :all)
      expect(page).to have_no_css("[data-test='home-reject-dialog']", visible: :all)
    end

    it "premendo la riga si apre la scheda, e lì la decisione c'è" do
      sign_in_as(owner)

      click_on_test "decision-open-full"

      expect(page).to have_current_path(member_home_approvals_item_path(kind: "review", id: ticket.id))
      expect_test "approvals-approve"
    end
  end

  it "cambia organizzazione dallo switcher" do
    org_b = create(:organization, name: "Org B")
    create(:membership, account: owner, organization: org_b, role: :member)

    sign_in_as(owner)
    find("[data-test='member-org-switch-#{org_b.id}']", visible: :all).click

    expect(page).to have_current_path(root_path)
    expect(page).to have_css("[data-test='member-org-switcher']", text: "Org B")
  end
end
