# frozen_string_literal: true

require "rails_helper"

# Comportamento dello Stimulus condiviso `char-counter` provato sul form Knowledge (dove nasce):
# conta i caratteri mentre si scrive e cambia colore avvicinandosi al tetto, così il limite non lo
# si scopre col salvataggio rifiutato. Il rifiuto vero lo fa il model (concern LengthBudget), qui si
# verifica solo l'avviso. Richiede un browser reale: gating js condiviso in spec/support/js_system.rb.
RSpec.describe "Ui — contatore caratteri", :js, type: :system do
  let(:org) { create(:organization) }
  let!(:project) { create(:project, organization: org) }
  let(:owner) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  let(:max) { Knowledge::Constants::BODY_MAX_CHARS }
  let(:counter) { "[data-test='knowledge-form-body-counter']" }

  # fill_in con 4.000 caratteri via tastiera è lentissimo: si scrive il valore e si emette l'input.
  def write_body(length)
    page.execute_script(<<~JS, length)
      const field = document.querySelector("[data-test='knowledge-form-body']")
      field.value = "x".repeat(arguments[0])
      field.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  it "conta i caratteri, avvisa vicino al tetto e segnala rosso oltre" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path

    expect(page).to have_css("#{counter}.text-gray-500", text: "0 / #{max}")

    write_body((max * App::Constants::LENGTH_WARN_RATIO).to_i + 10)
    expect(page).to have_css("#{counter}.text-amber-600")

    write_body(max + 1)
    expect(page).to have_css("#{counter}.text-red-600", text: "#{max + 1} / #{max}")

    write_body(10)
    expect(page).to have_css("#{counter}.text-gray-500", text: "10 / #{max}")
  end

  # Il prefill del template "decisione" scrive nel campo via JS: il contatore va notificato a mano,
  # altrimenti resta a zero mentre il corpo è già pieno.
  it "si aggiorna anche quando è il template decisione a riempire il corpo" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path

    expect(page).to have_css(counter, text: "0 / #{max}")
    # Il radio è sr-only: si clicca l'etichetta visibile, come fa una persona.
    find("[data-test='knowledge-form-kind-decision']").click

    expect(page).to have_no_css(counter, text: "0 / #{max}")
  end

  # Stesso Stimulus sul form dei commenti, con un tetto molto più basso: è lì che il contatore conta
  # davvero, perché a 240 caratteri lo si tocca scrivendo normalmente.
  describe "sul commento di un ticket" do
    let(:comment_max) { Ticketing::Constants::COMMENT_MAX_CHARS }
    let(:comment_counter) { "[data-test='member-ticket-comment-counter']" }
    let(:ticket) { create(:ticket, project: project, organization: org) }

    def write_comment(length)
      page.execute_script(<<~JS, length)
        const field = document.querySelector("[data-test='member-ticket-comment-body']")
        field.value = "x".repeat(arguments[0])
        field.dispatchEvent(new Event("input", { bubbles: true }))
      JS
    end

    # La discussione vive nella sua scheda dal CYRA-219: senza `tab`, la pagina apre il Dettaglio e il
    # form del commento non è nemmeno renderizzato.
    it "conta, avvisa in ambra vicino al tetto e va in rosso oltre i 240" do
      sign_in_as(owner)
      visit member_ticket_path(ticket, tab: "discussion")
      # CYRA-883 — the counter shows once the field is in use.
      find("[data-test='member-ticket-comment-body']").click

      expect(page).to have_css("#{comment_counter}.text-gray-500", text: "0 / #{comment_max}")

      write_comment((comment_max * App::Constants::LENGTH_WARN_RATIO).to_i + 5)
      expect(page).to have_css("#{comment_counter}.text-amber-600")

      write_comment(comment_max + 1)
      expect(page).to have_css("#{comment_counter}.text-red-600", text: "#{comment_max + 1} / #{comment_max}")
    end

    # Nessun maxlength: il browser troncherebbe in silenzio e chi scrive perderebbe testo senza
    # accorgersene. Il contatore avvisa, il model rifiuta — il campo non censura.
    it "non tronca il testo mentre si scrive" do
      sign_in_as(owner)
      visit member_ticket_path(ticket, tab: "discussion")
      write_comment(comment_max + 50)

      value = page.evaluate_script("document.querySelector(\"[data-test='member-ticket-comment-body']\").value.length")
      expect(value).to eq(comment_max + 50)
    end
  end

  # Bersaglio esplicito invece della quota del tetto (CYRA-263). Sull'analisi tecnica la quota
  # avvisava a 1.200 su 1.500: troppo tardi per accorciare, e infatti le analisi saturavano il tetto
  # ogni volta (1.417, 1.462, 1.483, 1.444, 1.498). Il tetto dice quanto puoi scrivere, il bersaglio
  # quanto dovresti — e sono due numeri, non uno.
  describe "sull'analisi tecnica di un ticket" do
    let(:cap) { Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS }
    let(:target) { Ticketing::Constants::TECHNICAL_ANALYSIS_TARGET_CHARS }
    let(:analysis_counter) { "[data-test='ticket-technical-analysis-counter']" }

    def write_analysis(length)
      page.execute_script(<<~JS, length)
        const field = document.querySelector("[data-test='ticket-technical-analysis']")
        field.value = "x".repeat(arguments[0])
        field.dispatchEvent(new Event("input", { bubbles: true }))
      JS
    end

    it "avvisa al bersaglio, molto prima del tetto" do
      sign_in_as(owner)
      visit new_member_ticket_path(project_id: project.id)

      expect(page).to have_css("#{analysis_counter}.text-gray-500", text: "0 / #{cap}")

      write_analysis(target - 1)
      expect(page).to have_css("#{analysis_counter}.text-gray-500")

      write_analysis(target + 1)
      expect(page).to have_css("#{analysis_counter}.text-amber-600")
    end

    # Il punto della modifica: alla quota vecchia (80% del tetto) il contatore era ancora grigio a
    # 950 caratteri. Se questo test passasse anche senza il bersaglio, non starebbe misurando nulla.
    it "avvisa prima di dove avvisava la quota del tetto" do
      sign_in_as(owner)
      visit new_member_ticket_path(project_id: project.id)

      write_analysis((cap * App::Constants::LENGTH_WARN_RATIO).to_i - 1)
      expect(page).to have_css("#{analysis_counter}.text-amber-600")
    end

    it "resta rosso oltre il tetto" do
      sign_in_as(owner)
      visit new_member_ticket_path(project_id: project.id)

      write_analysis(cap + 1)
      expect(page).to have_css("#{analysis_counter}.text-red-600", text: "#{cap + 1} / #{cap}")
    end
  end
end
