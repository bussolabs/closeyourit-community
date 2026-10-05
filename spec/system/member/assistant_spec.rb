# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Assistente help", type: :system do
  let(:org) { create(:organization) }
  let(:member) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    account
  end

  # sign_in_as è fornito da JsSystemSupport (attende il completamento del login async prima di navigare).

  describe "senza JavaScript (fallback progressivo)" do
    before { driven_by(:rack_test) }

    it "shows the AI button in the topbar of a member page" do
      sign_in_as(member)
      visit member_projects_path
      expect(page).to have_css("[data-test='assistant-controls'] [data-test='assistant-trigger']", visible: :all)
    end

    it "il pannello resta usabile senza JS: scrivo e invio, il turno viene registrato" do
      sign_in_as(member)
      visit member_assistant_panel_path
      expect(page).to have_css("[data-test='assistant-greeting']")

      find("[data-test='assistant-input']").set("come apro un ticket?")
      expect { find("[data-test='assistant-send']").click }
        .to change(Assistant::Message, :count).by(2)
    end
  end

  describe "con JavaScript", :js do
    it "opens the assistant column from the AI button and shows the composer" do
      sign_in_as(member)
      visit member_projects_path

      find("[data-test='assistant-trigger']").click

      expect(page).to have_css("[data-test='assistant-input']", wait: 5)
      expect(page).to have_css("[data-test='assistant-greeting']")
      expect(page).to have_no_css("[data-test='assistant-panel-error']")
      expect(page).to have_css("[data-test='assistant-trigger'][aria-expanded='true']")
    end

    it "narrows the page and keeps the column open across page changes" do
      sign_in_as(member)
      visit member_projects_path
      full_width = page.evaluate_script("document.getElementById('main-content').offsetWidth")

      find("[data-test='assistant-trigger']").click
      find("[data-test='assistant-input']").set("draft kept")
      expect(page.evaluate_script("document.getElementById('main-content').offsetWidth")).to be < full_width

      find("[data-test='member-nav-todos']").click
      expect(page).to have_current_path(member_todo_lists_path)
      expect(page).to have_field(with: "draft kept")
      expect(page).to have_css("[data-test='assistant-trigger'][aria-expanded='true']")

      find("[data-test='assistant-trigger']").click
      expect(page).to have_no_css("[data-test='assistant-panel']")
      expect(page).to have_css("[data-test='assistant-trigger'][aria-expanded='false']")
    end

    # CYRA-558 — scenario 2: quando il corpo del pannello non arriva, l'utente deve leggerlo e poter
    # riprovare, invece di restare davanti al cerchietto che gira. Il caricamento si fa fallire
    # puntandolo a una pagina che esiste ma NON contiene il pannello (la lista delle conversazioni è
    # l'unica pagina member senza il widget): risposta valida, corpo che non arriva, nessun errore
    # sollevato dal server che farebbe fallire il test per un motivo diverso da quello in prova.
    it "se il caricamento non riesce lo dichiara e offre di riprovare" do
      sign_in_as(member)
      visit member_projects_path
      expect(page).to have_css("[data-test='assistant-trigger']")

      point_panel_to(member_assistant_conversations_path)
      find("[data-test='assistant-trigger']").click

      expect(page).to have_css("[data-test='assistant-panel-error']", wait: 5)
      expect(page).to have_no_css("[data-test='assistant-panel-loading']")

      point_panel_to(member_assistant_panel_path)
      find("[data-test='assistant-panel-retry']").click

      expect(page).to have_css("[data-test='assistant-input']", wait: 5)
      expect(page).to have_no_css("[data-test='assistant-panel-error']")
    end

    def point_panel_to(path)
      page.execute_script(
        "document.querySelector(\"[data-test='assistant-widget']\")" \
        ".setAttribute('data-ui--assistant-url-value', arguments[0])", path
      )
    end
  end

  # Page refactor (2026-10-01): the conversation page reuses the panel composer behaviour.
  describe "conversation page", :js do
    it "writes an example question in the field and keeps Escape harmless without a panel" do
      conversation = Assistant::Conversation.create!(account: member, organization: org)
      sign_in_as(member)
      visit member_assistant_conversation_path(conversation)

      question = I18n.t("member.assistant.panel.suggestions").first
      find("[data-test='assistant-conversation'] [data-test='assistant-suggestion']", text: question).click
      expect(find("[data-test='assistant-conversation'] [data-test='assistant-input']").value).to eq(question)

      find("body").send_keys(:escape)
      expect(page).to have_css("[data-test='assistant-conversation']")
    end

    it "hides the example questions as soon as a message arrives live" do
      conversation = Assistant::Conversation.create!(account: member, organization: org)
      sign_in_as(member)
      visit member_assistant_conversation_path(conversation)
      expect(page).to have_css("[data-test='assistant-conversation'] [data-test='assistant-greeting']")

      message = conversation.messages.create!(role: :user, status: :complete, content: "Hi", organization: org)
      html = ApplicationController.render(partial: "member/assistant_conversations/message", locals: { message: message })
      page.execute_script("document.getElementById(arguments[0]).insertAdjacentHTML('beforeend', arguments[1])",
                          "assistant_messages_#{conversation.id}", html)

      expect(page).to have_no_css("[data-test='assistant-conversation'] [data-test='assistant-greeting']")
    end
  end
end
