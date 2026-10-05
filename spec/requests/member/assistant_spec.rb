# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Assistant", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization: org, role: :member)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def conversation_for(owner)
    Assistant::Conversation.create!(account: owner, organization: org)
  end

  describe "autenticazione" do
    it "non autenticato → redirect al login" do
      get member_assistant_conversations_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET index" do
    it "mostra le mie conversazioni" do
      sign_in(account)
      Assistant::Conversation.create!(account:, organization: org, title: "La mia domanda", last_message_at: Time.current)

      get member_assistant_conversations_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("La mia domanda")
    end

    it "senza conversazioni: intestazione standard e stato vuoto che spiega a cosa serve" do
      sign_in(account)
      get member_assistant_conversations_path

      html = Nokogiri::HTML(response.body)
      # CYRA-883 — an index trail would only repeat the title, so the header renders none.
      expect(html.at_css("[data-test='breadcrumb']")).to be_nil
      expect(html.at_css("[data-test='assistant-conversations-empty'] [data-test='empty-example']")).to be_present
    end
  end

  describe "POST create" do
    it "crea una conversazione e reindirizza alla sua show" do
      sign_in(account)
      expect { post member_assistant_conversations_path }.to change(Assistant::Conversation, :count).by(1)
      expect(response).to redirect_to(member_assistant_conversation_path(Assistant::Conversation.last))
    end

    it "con testo crea la conversazione e posta subito il primo turno (utente + assistente)" do
      sign_in(account)
      expect {
        post member_assistant_conversations_path, params: { text: "come apro un ticket?" }
      }.to change(Assistant::Conversation, :count).by(1).and change(Assistant::Message, :count).by(2)
    end
  end

  describe "GET show" do
    it "conversazione propria → 200, con la breadcrumb che riporta all'elenco" do
      sign_in(account)
      get member_assistant_conversation_path(conversation_for(account))
      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='breadcrumb'] a[href='#{member_assistant_conversations_path}']")).to be_present
    end

    it "conversazione di un altro utente → 404 (anti-BOLA)" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)

      get member_assistant_conversation_path(conversation_for(other))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET panel (corpo del pannello flottante)" do
    # CYRA-916
    it "says where the assistant comes from when no AI service is connected" do
      saved = ENV.to_h.slice("AI_BASE_URL", "AI_API_KEY")
      ENV.delete("AI_BASE_URL")
      ENV.delete("AI_API_KEY")
      sign_in(account)
      get member_assistant_panel_path

      expect(response.body).to include("assistant-not-configured")
      expect(response.body).not_to include("assistant-input")
    ensure
      saved.each { |name, value| ENV[name] = value }
    end

    it "è di sola lettura: senza conversazioni mostra l'empty-state (saluto + composer) SENZA creare nulla" do
      sign_in(account)
      expect { get member_assistant_panel_path }.not_to change(Assistant::Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="assistant-greeting"')
      expect(response.body).to include('data-test="assistant-input"')
    end

    # CYRA-436 — a pannello vuoto quattro domande di esempio cliccabili, e sopra il campo una riga che
    # dichiara di cosa si occupa l'assistente e cosa non fa.
    it "propone quattro domande di esempio cliccabili nell'empty-state" do
      sign_in(account)
      get member_assistant_panel_path

      expect(I18n.t("member.assistant.panel.suggestions").size).to eq(4)
      expect(response.body.scan('data-test="assistant-suggestion"').size).to eq(4)
    end

    it "says in one line under the field what the assistant does, then the keys" do
      sign_in(account)
      get member_assistant_panel_path
      html = Capybara.string(response.body)

      expect(html).to have_css("form [data-test='assistant-input'] ~ [data-test='assistant-mic']", visible: :all)
      expect(html).to have_css("footer form + [data-test='assistant-note']", text: I18n.t("member.assistant.panel.note"))
      expect(html).to have_css("[data-test='assistant-note'] + [data-test='assistant-compose-hint']",
                               text: I18n.t("member.assistant.panel.compose_hint"))
      expect(html).to have_no_css("footer [data-test='assistant-capability']")
    end

    it "riusa la conversazione più recente e ne mostra i messaggi" do
      sign_in(account)
      conversation = conversation_for(account)
      conversation.messages.create!(role: :user, status: :complete, content: "una domanda salvata", organization: org)

      get member_assistant_panel_path
      expect(response.body).to include("una domanda salvata")
    end

    it "è idempotente: riusa la conversazione esistente, non ne crea una nuova ad ogni apertura" do
      sign_in(account)
      conversation_for(account)
      expect { get member_assistant_panel_path }.not_to change(Assistant::Conversation, :count)
    end
  end

  describe "POST messages create" do
    it "con testo valido crea il turno (utente + assistente) e accoda il job" do
      sign_in(account)
      conversation = conversation_for(account)

      expect {
        post member_assistant_conversation_messages_path(conversation), params: { text: "come apro un ticket?" }
      }.to change { conversation.messages.count }.by(2).and have_enqueued_job(Assistant::ConverseJob)

      expect(response).to redirect_to(member_assistant_conversation_path(conversation))
    end

    it "su conversazione di un altro utente → 404" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)

      post member_assistant_conversation_messages_path(conversation_for(other)), params: { text: "ciao" }
      expect(response).to have_http_status(:not_found)
    end

    it "con testo vuoto non crea messaggi" do
      sign_in(account)
      conversation = conversation_for(account)

      expect {
        post member_assistant_conversation_messages_path(conversation), params: { text: "  " }
      }.not_to change { conversation.messages.count }
    end
  end

  describe "GET messages show (fallback di riconciliazione streaming)" do
    it "una bolla in streaming porta il controller di riconciliazione col suo stato" do
      sign_in(account)
      conversation = conversation_for(account)
      message = conversation.messages.create!(role: :assistant, status: :streaming, content: nil, organization: org)

      get member_assistant_conversation_message_path(conversation, message)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-status="streaming"')
      expect(response.body).to include("ui--assistant-reconcile")
    end

    it "una bolla finalizzata NON porta il controller di riconciliazione (il polling si ferma)" do
      sign_in(account)
      conversation = conversation_for(account)
      message = conversation.messages.create!(role: :assistant, status: :complete, content: "Vai su Ticket", organization: org)

      get member_assistant_conversation_message_path(conversation, message)

      expect(response.body).to include('data-status="complete"')
      expect(response.body).not_to include("ui--assistant-reconcile")
    end

    it "messaggio di una conversazione altrui → 404 (anti-BOLA)" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      other_conversation = conversation_for(other)
      message = other_conversation.messages.create!(role: :user, status: :complete, content: "x", organization: org)

      get member_assistant_conversation_message_path(other_conversation, message)
      expect(response).to have_http_status(:not_found)
    end
  end

  # L'AI la offre il sistema (CYRA-765): non c'è più un servizio da collegare per organizzazione,
  # quindi il campo per scrivere c'è sempre e nessun avviso «non collegato» compare.
  describe "senza credenziali di integrazione" do
    it "il pannello offre comunque il campo per scrivere e non mostra avvisi di collegamento" do
      sign_in(account)
      get member_assistant_panel_path

      documento = Nokogiri::HTML(response.body)
      expect(documento.at_css("[data-test='integration-not-connected']")).to be_nil
      expect(documento.at_css("[data-test='assistant-input']")).to be_present
    end

    it "inviando una domanda nascono i messaggi e il lavoro finisce in coda" do
      sign_in(account)
      conversation = conversation_for(account)

      expect do
        post member_assistant_conversation_messages_path(conversation), params: { text: "ciao" }
      end.to change { conversation.messages.count }.by(2)
      expect(Assistant::ConverseJob).to have_been_enqueued
    end
  end

  # Page refactor (2026-10-01): same shape as the other refactored pages.
  describe "page layout" do
    def html
      Capybara.string(response.body)
    end

    def conversation_with(title:, answer: "Open Members and press Invite.", kind: :help)
      conversation = Assistant::Conversation.create!(account:, organization: org, title:, kind:, last_message_at: Time.current)
      conversation.messages.create!(role: :user, status: :complete, content: title, organization: org)
      conversation.messages.create!(role: :assistant, status: :complete, content: answer, organization: org)
      conversation
    end

    describe "list" do
      before { sign_in(account) }

      it "has a subtitle and says when conversations are deleted" do
        conversation_with(title: "How do I invite a colleague?")
        get member_assistant_conversations_path

        expect(response.body).to include(I18n.t("member.assistant.list.subtitle"))
        expect(html).to have_css("[data-test='assistant-retention']",
                                 text: I18n.t("member.assistant.list.retention", days: Assistant::Constants::RETENTION_DAYS))
      end

      it "shows the message count and the last answer on each row" do
        conversation = conversation_with(title: "How do I invite a colleague?")
        get member_assistant_conversations_path

        row = html.find("[data-test='assistant-conversation-row-#{conversation.id}']")
        expect(row).to have_css("[data-test='assistant-conversation-count']", text: I18n.t("member.assistant.list.messages", count: 2))
        expect(row).to have_css("[data-test='assistant-conversation-preview']", text: "Open Members and press Invite.")
      end

      it "marks the conversations started from the terminal" do
        terminal = conversation_with(title: "Which errors grew yesterday?", kind: :tools)
        get member_assistant_conversations_path

        expect(html.find("[data-test='assistant-conversation-row-#{terminal.id}']"))
          .to have_css("[data-test='assistant-from-terminal']", text: I18n.t("member.assistant.list.from_terminal"))
      end

      it "leaves out the conversations without messages" do
        conversation_with(title: "How do I invite a colleague?")
        empty = conversation_for(account)
        get member_assistant_conversations_path

        expect(html).to have_no_css("[data-test='assistant-conversation-row-#{empty.id}']")
      end

      it "searches the titles" do
        found = conversation_with(title: "How do I invite a colleague?")
        other = conversation_with(title: "Where are the errors?")
        get member_assistant_conversations_path(q: "invite")

        expect(html).to have_css("[data-test='assistant-search'][data-keyboard-search]")
        expect(html).to have_css("[data-test='assistant-conversation-row-#{found.id}']")
        expect(html).to have_no_css("[data-test='assistant-conversation-row-#{other.id}']")
      end
    end

    describe "conversation" do
      before { sign_in(account) }

      it "offers a new conversation from inside a conversation" do
        get member_assistant_conversation_path(conversation_with(title: "How do I invite a colleague?"))

        expect(html).to have_css("[data-test='assistant-new']")
      end

      it "says in one line under the field what the assistant does and sends with Enter" do
        get member_assistant_conversation_path(conversation_with(title: "How do I invite a colleague?"))

        expect(html).to have_css("form + [data-test='assistant-note']", text: I18n.t("member.assistant.panel.note"))
        expect(html).to have_css("[data-test='assistant-input'][data-action*='ui--assistant#submitOnEnter']")
        expect(html).to have_css("[data-test='assistant-note'] + [data-test='assistant-compose-hint']",
                                 text: I18n.t("member.assistant.panel.compose_hint"))
        expect(html).to have_no_css("[data-test='assistant-capability']")
      end

      it "puts the microphone inside the field, recording into this conversation without opening the panel" do
        conversation = conversation_with(title: "How do I invite a colleague?")
        get member_assistant_conversation_path(conversation)

        expect(html).to have_css("form [data-test='assistant-input'] ~ [data-test='assistant-mic']", visible: :all)
        form = html.find("form[data-controller='ui--voice-inline']")
        expect(form["data-ui--voice-inline-url-value"]).to eq(member_assistant_voice_path(conversation_id: conversation.id))
        expect(form["data-ui--voice-inline-open-panel-value"]).to eq("false")
      end

      it "proposes example questions while the conversation is empty" do
        get member_assistant_conversation_path(conversation_for(account))

        expect(html).to have_css("[data-test='assistant-suggestion']", count: I18n.t("member.assistant.panel.suggestions").size)
      end

      it "shows the time of each message and a lighter Assistant label" do
        get member_assistant_conversation_path(conversation_with(title: "How do I invite a colleague?"))

        expect(html).to have_css("[data-test='assistant-message-time']", count: 2)
        expect(html).to have_css("[data-test='assistant-message-label']:not(.uppercase)")
      end

      it "keeps the thread in a narrower reading column" do
        get member_assistant_conversation_path(conversation_with(title: "How do I invite a colleague?"))

        expect(html).to have_css("[data-test='assistant-conversation'] .max-w-3xl [data-test='assistant-messages']")
      end
    end

    it "links the floating panel to every conversation" do
      sign_in(account)
      get member_assistant_panel_path

      expect(html).to have_css("header a[data-test='assistant-all-conversations'][href='#{member_assistant_conversations_path}'][data-turbo-frame='_top']")
      expect(html).to have_no_css("footer [data-test='assistant-all-conversations']")
    end
  end

  describe "voice bubbles (CYRA-908)" do
    let(:conversation) { Assistant::Conversation.create!(account: account, organization: org, last_message_at: Time.current) }

    before { sign_in(account) }

    def voice(**attrs)
      conversation.messages.create!(organization: org, role: :user, transcribed: true, **attrs)
    end

    def t_voice(key) = I18n.t("member.assistant.voice.#{key}", locale: account.effective_locale)

    it "shows a transcribing bubble that keeps reconciling" do
      voice(status: :transcribing)
      get member_assistant_panel_path
      expect(response.body).to include(t_voice("transcribing"))
      expect(response.body).to include('data-status="transcribing"', "ui--assistant-reconcile")
    end

    it "tells the user to speak again when nothing was heard" do
      voice(status: :failed, error_code: Assistant::Constants::NOT_HEARD_CODE)
      get member_assistant_panel_path
      expect(response.body).to include(CGI.escapeHTML(t_voice("not_heard")))
    end

    it "offers to correct a transcribed message, not a typed one" do
      voice(status: :complete, content: "apri CYSL")
      conversation.messages.create!(organization: org, role: :user, status: :complete, content: "typed")
      get member_assistant_panel_path
      expect(response.body.scan('data-test="assistant-correct"').size).to eq(1)
    end

    it "passes the correction to the service" do
      original = voice(status: :complete, content: "apri CYSL")
      allow(Assistant::PostMessage).to receive(:call).and_call_original

      post member_assistant_conversation_messages_path(conversation),
           params: { text: "apri CYFL", correction_of: original.id }, as: :turbo_stream

      expect(Assistant::PostMessage).to have_received(:call)
        .with(conversation: conversation, text: "apri CYFL", correction_of: original.id)
    end
  end
end
