# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ideas", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:member) { create(:account, name: "Marco Rossi") }
  let(:mate) { create(:account, name: "Dana Kim") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }

  before do
    Types::InstallDefaults.call(organization: org)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: mate, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: mate, project: project)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "crea un'idea dal form (progetto preselezionato da querystring)" do
    sign_in_as(member)
    visit new_member_idea_path(project_id: project.id)

    fill_test "idea-title", with: "Dark mode"
    fill_test "idea-problem-field", with: "La dashboard acceca di notte."
    fill_test "idea-solution-field", with: "Tema scuro di sistema."
    fill_test "idea-stakeholders", with: "Team Mobile, Clienti"
    click_on_test "idea-submit"

    idea = Ideas::Idea.order(:created_at).last
    expect(idea).to have_attributes(title: "Dark mode", author_id: member.id, project_id: project.id)
    expect(idea.problem).to eq("La dashboard acceca di notte.")
    expect(idea.solution).to eq("Tema scuro di sistema.")
    expect(idea.stakeholders).to eq([ "Team Mobile", "Clienti" ])
    expect(page).to have_current_path(member_idea_path(idea))
    expect_test "flash-notice"
    expect_test "idea-status"
  end

  it "propone un'idea dalla pagina del progetto (progetto bloccato)" do
    sign_in_as(member)
    visit member_project_path(project)
    click_on_test "project-new-idea"

    # Aperta dal progetto: il progetto è fisso (chip read-only), non un select.
    expect_test "idea-project-locked"
    fill_test "idea-title", with: "Notifiche push"
    fill_test "idea-problem-field", with: "Gli aggiornamenti importanti passano inosservati."
    click_on_test "idea-submit"

    idea = Ideas::Idea.order(:created_at).last
    expect(idea).to have_attributes(title: "Notifiche push", author_id: member.id, project_id: project.id)
    expect(page).to have_current_path(member_idea_path(idea))
  end

  # CYRA-360 Scenario 2 — il voto sta in chiaro, dice a cosa serve e mostra chi l'ha già dato.
  it "vota dal riquadro dell'interesse e il proprio nome compare fra chi ha votato" do
    idea = create(:idea, organization: org, project: project)
    sign_in_as(member)
    visit member_idea_path(idea)

    expect(page).to have_css("[data-test='idea-interest'] [role='tooltip']", text: I18n.t("member.ideas.interest.explainer"), visible: :all)
    expect_test "idea-voters-empty"

    expect { click_on_test "idea-vote" }.to change { idea.reload.votes_count }.from(0).to(1)
    expect_test "flash-notice"
    expect(page).to have_css("[data-test='idea-voters']", text: "Marco Rossi")

    expect { click_on_test "idea-vote" }.to change { idea.reload.votes_count }.from(1).to(0)
    expect_test "idea-voters-empty"
  end

  # CYRA-360 Scenario 1 — dalla bacheca si vede subito quali idee si sono mosse: l'ordine è
  # dichiarato in pagina e la colonna dell'ultimo movimento lo rende controllabile riga per riga.
  it "la bacheca dichiara l'ordinamento e mette in cima l'idea mossa più di recente" do
    stop = create(:idea, organization: org, project: project, title: "Ferma da settimane",
                          created_at: 2.hours.ago, updated_at: 2.hours.ago)
    mossa = create(:idea, organization: org, project: project, title: "Ripresa ieri",
                          created_at: 5.days.ago, updated_at: 5.days.ago)
    create(:idea_comment, idea: mossa, organization: org)
    3.times { create(:idea_vote, idea: stop) }

    sign_in_as(member)
    visit member_ideas_path

    expect(page).to have_css("[data-test='sort-last_activity-hint'][aria-label='#{I18n.t('member.ideas.sort_note')}']")
    titoli = page.all("[data-test='idea-row'] > :first-child a").map(&:text)
    expect(titoli).to eq([ mossa.title, stop.title ])
  end

  it "commenta un'idea di un collega" do
    idea = create(:idea, organization: org, project: project, author: mate)
    sign_in_as(member)
    visit member_idea_path(idea)

    fill_test "member-idea-comment-body", with: "Serve anche la variante ad alto contrasto."
    click_on_test "member-idea-comment-submit"

    expect(idea.reload.comments_count).to eq(1)
    comment = idea.comments.first
    expect_test "member-idea-comment-#{comment.id}"
  end

  it "aggiunge e rimuove un case dalla pagina della propria idea" do
    idea = create(:idea, organization: org, project: project, author: member)
    sign_in_as(member)
    visit member_idea_path(idea)

    expect_test "idea-cases-empty"
    click_on_test "idea-case-form-open"
    fill_test "member-idea-case-title", with: "Onboarding nuovo cliente"
    fill_test "member-idea-case-description", with: "Il primo accesso guidato."
    click_on_test "member-idea-case-submit"

    expect(idea.reload.cases_count).to eq(1)
    idea_case = idea.cases.first
    expect_test "member-idea-case-#{idea_case.id}"
    expect(page).to have_css("[data-test='member-idea-case-title-#{idea_case.id}']", text: "Onboarding nuovo cliente")

    expect { click_on_test "member-idea-case-delete-#{idea_case.id}" }
      .to change { idea.reload.cases_count }.by(-1)
  end

  it "converte la propria idea in ticket dal form di preview (fallback senza JS)" do
    idea = create(:idea, organization: org, project: project, author: member,
                         title: "Wishlist condivisa", problem: "Condividere la wishlist con amici.")
    create(:idea_comment, idea: idea, organization: org, body: "Aggiungerei i permessi di sola lettura.")

    sign_in_as(member)
    visit member_idea_path(idea)
    click_on_test "idea-convert"

    # Senza JS il form parte col fallback (titolo/corpo dell'idea) — sempre submittabile.
    fill_test "idea-convert-description", with: "Wishlist condivisibile con permessi di sola lettura."
    click_on_test "idea-convert-submit"

    idea.reload
    expect(idea).to be_status_converted
    expect(idea.ticket).to be_present
    expect(page).to have_current_path(member_ticket_path(idea.ticket))
    expect_test "ticket-idea-link"

    # The converted idea is frozen: ticket and date in the Details, no comment form.
    visit member_idea_path(idea)
    expect_test "idea-converted-on"
    expect_test "idea-comments-locked"
  end

  # CYRA-369 Scenario 1 — dall'idea già diventata ticket si arriva al ticket, non al cestino.
  it "dall'idea convertita l'azione principale porta al ticket collegato" do
    idea = create(:idea, :converted, organization: org, project: project, author: member)
    sign_in_as(member)
    visit member_idea_path(idea)

    click_on_test "idea-open-ticket"
    expect(page).to have_current_path(member_ticket_path(idea.ticket))
  end

  # CYRA-370 Scenario 1 — dalla lista filtrata sulle convertite si vede in quale ticket è finita
  # ciascuna idea, senza aprirle una per una.
  it "dalla lista delle idee convertite si arriva al ticket col codice mostrato in riga" do
    idea = create(:idea, :converted, organization: org, project: project, author: member,
                                     title: "Wishlist condivisa")
    sign_in_as(member)
    visit member_ideas_path(status: [ "converted" ])

    expect(page).to have_css("[data-test='idea-ticket-link']", text: idea.ticket.code)
    click_on_test "idea-ticket-link"
    expect(page).to have_current_path(member_ticket_path(idea.ticket))
  end

  # CYRA-369 Scenario 2 — l'eliminazione non sta più accanto al pulsante che converte.
  it "l'eliminazione dell'idea aperta vive nel menu secondario, non accanto a Converti" do
    idea = create(:idea, organization: org, project: project, author: member)
    sign_in_as(member)
    visit member_idea_path(idea)

    expect_test "idea-convert"
    menu = find("[data-test='idea-more-menu']")
    expect(menu).to have_css("[data-test='idea-delete']", visible: :all)
    expect(menu).to have_no_css("[data-test='idea-convert']", visible: :all)

    expect { find("[data-test='idea-delete']", visible: :all).click }
      .to change(Ideas::Idea, :count).by(-1)
    expect(page).to have_current_path(member_ideas_path)
  end

  it "archivia e riapre la propria idea" do
    idea = create(:idea, organization: org, project: project, author: member)
    sign_in_as(member)
    visit member_idea_path(idea)

    click_on_test "idea-menu-trigger"
    click_on_test "idea-archive"
    expect_test "idea-archived-banner"
    expect(idea.reload).to be_status_archived
    expect_test "idea-archived-banner"

    click_on_test "idea-reopen"
    expect(idea.reload).to be_status_open
  end

  it "la voce Idee sta nel gruppo Prodotto e porta alla index" do
    sign_in_as(member)
    # Si parte dalla panoramica del gruppo: il gruppo che contiene la pagina aperta parte aperto,
    # quindi la voce è cliccabile senza doverlo espandere a mano (cosa che rack_test non sa fare).
    visit member_product_path
    click_on_test "member-nav-ideas"
    expect(page).to have_current_path(member_ideas_path)
    expect_test "ideas-counts"
  end
end
