# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Plancia delle approvazioni", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }
  let(:project) { create(:project, organization: org) }
  let(:review_status) { create(:ticket_status, :in_review, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  # I box "Respingi" e "Chiedi precisazioni" vivono in un <details> chiuso: senza JS il contenuto
  # c'è nel DOM ma Capybara non lo considera visibile. Si compila e si invia col visible: :all —
  # è esattamente ciò che fa un browser dopo aver aperto il pannello.
  def fill_hidden(tag, with:)
    find("[data-test='#{tag}']", visible: :all).set(with)
  end

  def click_hidden(tag)
    find("[data-test='#{tag}']", visible: :all).click
  end

  def review_ticket(**attributes)
    create(:ticket, organization: org, project:,
                    status: review_status, reviewer: owner, **attributes)
  end

  # Una lavorazione col piano pronto e in attesa del via libera: il piano vero serve, o l'approvazione
  # non trova niente da approvare e resta in coda.
  def planned_workflow(planned_at: Time.current, **attributes)
    ticket = create(:ticket, organization: org, project:, **attributes)
    workflow = create(:agent_workflow, ticket:, triaged_at: planned_at, planned_at:,
                                       ticket_snapshot_digest: "snapshot")
    Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, workflow:, organization: org),
                         technical_analysis: "Il piano", scenarios: [ "Uno" ], definition_of_done: [],
                         notes: [], ticket_snapshot_digest: "snapshot")
    workflow
  end

  it "dice che non c'è niente da decidere quando la coda è vuota" do
    sign_in_as(owner)
    visit member_home_approvals_path

    expect_test "approvals-empty"
  end

  # CYRA-592 — la plancia mostra tutto e non apre niente da sola: si sceglie la riga su cui agire.
  it "elenca le lavorazioni e apre quella che si sceglie" do
    vecchio = review_ticket(title: "Il più fermo")
    vecchio.update_column(:updated_at, 1.year.ago)
    review_ticket(title: "Arrivato ora")

    sign_in_as(owner)
    visit member_home_approvals_path

    expect(all("[data-test='approvals-board-row']").size).to eq(2)
    expect(page).to have_no_css("[data-test='approvals-detail']")

    all("[data-test='approvals-board-decide']").last.click

    within_test("approvals-detail") { expect(page).to have_content("Arrivato ora") }
  end

  it "accettare con una nota chiude la card e apre da sola la successiva" do
    create(:ticket_status, :done, organization: org)
    prima = review_ticket(title: "Prima")
    prima.update_column(:updated_at, 1.year.ago)
    review_ticket(title: "Seconda")

    sign_in_as(owner)
    visit member_home_approvals_path(item: "review:#{prima.id}")
    fill_test "approvals-approve-note", with: "Occhio al deploy"
    click_on_test "approvals-approve"

    within_test("approvals-detail") { expect(page).to have_content("Seconda") }
    expect(prima.reload.status.category).to eq("done")
    expect(prima.comments.pluck(:body)).to include("Occhio al deploy")
  end

  # CYRA-267 — il giro intero del riaccodo: una sola pressione dentro la card, e la fase che la revisione
  # aveva lasciato ferma torna proposta alle macchine.
  it "il riaccodo dentro la card rimette in coda la lavorazione ferma" do
    ticket = create(:ticket, organization: org, project:, title: "Lavorazione ferma")
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago)
    create(:agent_attempt, workflow:, organization: org, phase: "triage", status: :review_failed)

    sign_in_as(owner)
    visit member_home_approvals_path(item: "agent_plan:#{workflow.id}")
    click_on_test "approvals-requeue"

    expect(workflow.reload.ready_execution_phase).to eq("triage")
  end

  # CYRA-675 — il giro intero della rivalutazione: un clic sul piano che aspetta un sì, e la
  # pianificazione torna reclamabile perché rilegga il codice di oggi.
  it "la rivalutazione rimanda il piano alla pianificazione" do
    workflow = planned_workflow(title: "Da rivalutare")

    sign_in_as(owner)
    visit member_home_approvals_path(item: "agent_plan:#{workflow.id}")
    click_on_test "approvals-reassess"

    expect(workflow.reload).to have_attributes(planned_at: nil, ready_execution_phase: "planner")
  end

  # CYRA-504 metteva qui il giro intero del via libera: la produzione si fermava dopo lo staging e
  # una sola pressione sbloccava la fase che tagga. CYRA-629 ha tolto quella fermata — era la terza
  # volta che si chiedeva il permesso sullo stesso lavoro, e fra la seconda approvazione e il sito
  # vero non c'è nessuna scelta da fare, solo fatti da guardare.
  #
  # La prova ora è l'ASSENZA, e un'assenza va provata con cura: una pagina vuota perché mancano i
  # permessi o perché la coda non si carica supererebbe un `have_no_content` senza dire niente. Per
  # questo in coda c'è ANCHE un'altra lavorazione, che deve vedersi.
  it "conclusa la prova di staging non c'è nessuna card: il rilascio è già in coda" do
    ticket = create(:ticket, organization: org, project:,
                             title: "Pronta per la produzione")
    workflow = create(:agent_workflow, :closer_staging_completed, ticket:)
    create(:agent_attempt, workflow:, organization: org, phase: "closer_staging", status: :approved,
                           result: { "state" => "staging-released", "tag" => "v1.4.0-beta.1", "commit" => "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" })
    planned_workflow(title: "Questa invece aspetta me")

    sign_in_as(owner)
    visit member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    # La coda si vede e ha dentro qualcosa: l'assenza di sotto è un'assenza, non un vuoto.
    expect(page).to have_content("Questa invece aspetta me")
    expect(page).to have_no_content("Pronta per la produzione")
    expect(page).to have_no_selector("[data-test='approvals-approve']", visible: :all)

    # E non è ferma ad aspettare: è già in coda per il rilascio, senza che nessuno abbia premuto.
    expect(workflow.reload.ready_execution_phase).to eq("closer_production")
    expect(workflow.closer_production_approved_at).to be_nil
  end

  # CYRA-317 / CYRA-630 — il giro intero di ciò che va avanti da solo: non sta nella coda, si
  # raggiunge dal rimando nell'intestazione, da lì si apre la scheda della lavorazione — la stessa
  # che si apre da ogni altro elenco — vi si legge cosa la revisione ha respinto, e da lì si chiude
  # se si è impiantata. Chiudendola si torna nell'elenco da cui si era partiti, non nella coda.
  it "l'elenco si apre dalla coda, porta alla scheda e lascia chiudere la lavorazione" do
    ticket = create(:ticket, organization: org, project:, title: "Riprova da sola")
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago,
                                       triage_started_at: 1.day.ago, triaged_at: 1.day.ago)
    create(:agent_attempt, workflow:, organization: org, phase: "planner", status: :review_failed,
                           review: { "summary" => "Il piano non copre il rollback" },
                           review_status: :changes_requested)
    review_ticket(title: "Questa aspetta me")

    sign_in_as(owner)
    visit member_home_approvals_path

    # La coda parla solo di ciò che aspetta una decisione: la lavorazione che riprova non è lì.
    expect(page).to have_no_content("Riprova da sola")
    click_on_test "approvals-in-flight-link"

    expect(page).to have_content("Riprova da sola")
    click_on_test "approvals-in-flight-ticket"

    expect(page).to have_content("Il piano non copre il rollback")

    fill_hidden "approvals-reject-reason", with: "Non serve più"
    click_hidden "approvals-reject-submit"

    expect(workflow.reload.cancelled_at).to be_present
    # Si torna nell'elenco di partenza, che adesso è vuoto — non nella coda delle decisioni, dove
    # quella lavorazione non è mai stata.
    expect_test "approvals-in-flight-empty"
  end

  it "respingere pretende il motivo e riporta il ticket in lavorazione" do
    create(:ticket_status, :in_progress, organization: org)
    ticket = review_ticket(title: "Da respingere")

    sign_in_as(owner)
    visit member_home_approvals_path(item: "review:#{ticket.id}")
    fill_hidden "approvals-reject-reason", with: "Non passa i test"
    click_hidden "approvals-reject-submit"

    expect(ticket.reload.status.category).to eq("in_progress")
    expect_test "approvals-empty"
  end

  # CYRA-592 — chiesta una precisazione, la riga resta in elenco e lo dice nella colonna «Stato»:
  # niente più badge in più accanto al titolo, che era la stessa cosa scritta due volte.
  it "chiedere precisazioni lascia la riga in elenco, segnata in attesa di risposta" do
    ticket = review_ticket(title: "Da chiarire")

    sign_in_as(owner)
    visit member_home_approvals_path(item: "review:#{ticket.id}")
    fill_hidden "approvals-ask-text", with: "E il rollback?"
    click_hidden "approvals-ask-submit"

    within_test("approvals-board-state") do
      expect(page).to have_content(I18n.t("member.approvals.filters.waiting"))
    end
    expect(ticket.reload.status.review_gate?).to be(true)
    expect(ticket.comments.pluck(:body)).to include("E il rollback?")
  end

  # CYRA-284 — la selezione multipla nella coda. La barra vive dentro un contenitore [hidden] mostrato
  # dal JS: senza browser sta nel DOM ma non è "visibile", quindi si preme col visible: :all — è
  # esattamente ciò che fa un browser dopo aver spuntato la prima casella.
  it "accetta in blocco le card spuntate e lascia in coda quelle senza casella" do
    create(:ticket_status, :done, organization: org)
    primo = review_ticket(title: "Primo")
    primo.update_column(:updated_at, 1.year.ago)
    secondo = review_ticket(title: "Secondo")
    con_domanda = create(:ticket, organization: org, project:, title: "Con domanda")
    workflow = create(:agent_workflow, ticket: con_domanda, triage_started_at: 1.hour.ago)
    attempt = create(:agent_attempt, workflow:, organization: org)
    domanda = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

    sign_in_as(owner)
    visit member_home_approvals_path

    # Alla domanda dell'automa si risponde e basta: nessuna casella, né visibile né nascosta.
    expect(page).to have_no_css("[data-test='approvals-select-clarification:#{domanda.id}']", visible: :all)

    fill_test "approvals-select-review:#{primo.id}", with: true
    fill_test "approvals-select-review:#{secondo.id}", with: true
    click_hidden "approvals-bulk-approve"

    expect(primo.reload.status.category).to eq("done")
    expect(secondo.reload.status.category).to eq("done")
    expect(domanda.reload.answered_at).to be_nil
  end

  # CYRA-290 — il giro intero del filtro: accendo uno stato, ci resto dentro mentre decido, e la
  # coppia filtro + accettazione in blocco smaltisce un gruppo omogeneo in due mosse.
  it "accendere un filtro lascia in elenco solo quello stato e lo tiene acceso dopo la decisione" do
    create(:ticket_status, :done, organization: org)
    review_ticket(title: "Da revisionare")
    workflow = planned_workflow(planned_at: 1.year.ago, title: "Col piano pronto")

    sign_in_as(owner)
    # CYRA-651 — lo stato si sceglie dal menu a tendina della barra filtri; qui si entra dal link già
    # filtrato (il menu si accende con JS, e questa prova gira senza).
    visit member_home_approvals_path(state: "awaiting_approval")
    expect(find("select[data-test='approvals-filter-state']").value).to eq("awaiting_approval")

    expect(all("[data-test='approvals-board-row']").size).to eq(1)
    click_on_test "approvals-board-decide"
    within_test("approvals-detail") { expect(page).to have_content("Col piano pronto") }

    click_on_test "approvals-approve"

    # Il filtro è ancora acceso: l'elenco è vuoto perché quello stato si è svuotato, non perché il
    # filtro sia caduto — e il ticket in review resta fuori.
    expect(workflow.reload.approved_at).to be_present
    expect(page).to have_current_path(member_home_approvals_path(state: "awaiting_approval"))
    expect_test "approvals-board-empty"
  end

  it "col filtro acceso si accetta in blocco e si torna nello stesso stato" do
    create(:ticket_status, :done, organization: org)
    primo = review_ticket(title: "Primo")
    primo.update_column(:updated_at, 1.year.ago)
    secondo = review_ticket(title: "Secondo")
    workflow = planned_workflow(planned_at: 1.hour.ago, title: "Col piano pronto")

    sign_in_as(owner)
    visit member_home_approvals_path(state: "review")

    fill_test "approvals-select-review:#{primo.id}", with: true
    fill_test "approvals-select-review:#{secondo.id}", with: true
    click_hidden "approvals-bulk-approve"

    expect(page).to have_current_path(member_home_approvals_path(state: "review"))
    expect(primo.reload.status.category).to eq("done")
    expect(secondo.reload.status.category).to eq("done")
    # Il piano era fuori dal filtro: la sforbiciata non lo ha toccato.
    expect(workflow.reload.approved_at).to be_nil
  end

  it "si raggiunge dalla voce di menu" do
    review_ticket(title: "Qualcosa da decidere")

    sign_in_as(owner)
    click_on_test "member-nav-approvals"

    expect(page).to have_current_path(member_home_approvals_path)
    expect_test "approvals-board"
  end
end
