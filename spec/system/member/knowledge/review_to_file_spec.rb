# frozen_string_literal: true

require "rails_helper"

# CYRA-817 — il riquadro delle accettate da archiviare si aggiorna per conto suo, e questo crea una
# trappola che si vede solo con un browser vero: la barra di ricerca della coda sta FUORI dal
# riquadro e NON viene ridisegnata quando il riquadro cambia pagina. I suoi campi nascosti restano
# quelli del primo caricamento, e senza riallinearli all'indirizzo prima dell'invio ogni ricerca
# fra le proposte riportava le accettate alla prima pagina.
# Gating js (Chrome headless + skip se manca Chrome) condiviso in spec/support/js_system.rb.
RSpec.describe "Member knowledge — revisione, accettate da archiviare", :js, type: :system do
  let(:org) { create(:organization) }
  let!(:project) { create(:project, organization: org) }

  let(:owner) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # La più recente in cima: "Da archiviare 0" apre l'elenco, l'ultima accettata lo chiude.
  def da_archiviare(quante)
    Array.new(quante) do |i|
      create(:knowledge_page, organization: org, project: project,
                              title: "Da archiviare #{i}", reviewed_at: (i + 1).hours.ago)
    end
  end

  it "sfogliare le accettate aggiorna solo il riquadro, e l'indirizzo se lo ricorda" do
    create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
    da_archiviare(13)
    sign_in_as(owner)

    visit member_knowledge_reviews_path
    within_test("knowledge-review-to-file-pagination") { click_link "2" }

    expect(page).to have_text("Da archiviare 12")
    # La coda resta dov'era: il riquadro ha chiesto al server soltanto sé stesso.
    within_test("knowledge-review-waiting") { expect(page).to have_text("Proposta in attesa") }
    expect(current_url).to include("to_file_page=2")
  end

  it "cercare fra le proposte non riporta le accettate alla prima pagina" do
    create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
    create(:knowledge_page, :in_review, organization: org, project: project, title: "Nota da leggere")
    da_archiviare(13)
    sign_in_as(owner)

    visit member_knowledge_reviews_path
    within_test("knowledge-review-to-file-pagination") { click_link "2" }
    expect(page).to have_text("Da archiviare 12")

    # Col browser vero il pulsante Applica è nascosto (i filtri si applicano da soli): la ricerca
    # si invia dal campo, com'è nelle mani di chi usa la pagina.
    fill_test "knowledge-review-search", with: "Proposta"
    find("[data-test='knowledge-review-search']").send_keys(:enter)

    # La ricerca è avvenuta davvero: l'altra proposta è sparita dalla coda.
    expect(page).to have_no_text("Nota da leggere")
    expect(page).to have_text("Proposta in attesa")
    expect(current_url).to include("q=Proposta")
    # …e il riquadro delle accettate è rimasto alla pagina dov'era.
    expect(page).to have_text("Da archiviare 12")
    expect(current_url).to include("to_file_page=2")
  end
end
