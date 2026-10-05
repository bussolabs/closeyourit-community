# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Chat", type: :request do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  # Membro dell'org che vede i progetti passati (via ProjectMembership). La creazione fixture è
  # avvolta in allow_n_plus_one: creare più membri nello stesso example fa una tenant-check
  # (member_of_organization?) per account — query di setup identiche, non un N+1 di produzione.
  def member(seeing: [], organization: org)
    allow_n_plus_one do
      account = create(:account)
      create(:membership, account: account, organization: organization, role: :member)
      Array(seeing).each { |project| create(:project_membership, account: account, project: project) }
      account
    end
  end

  def dm_between(account_a, account_b)
    Chat::Conversations::FindOrCreateDirect.call(
      organization: org, account_a: account_a, account_b: account_b
    ).value
  end

  describe "autenticazione" do
    let(:conversation) { dm_between(member(seeing: [ shared ]), member(seeing: [ shared ])) }

    it "index non autenticato → redirect login" do
      get member_chat_conversations_path
      expect(response).to redirect_to(login_path)
    end

    it "show non autenticato → redirect login" do
      get member_chat_conversation_path(conversation)
      expect(response).to redirect_to(login_path)
    end

    it "create conversazione non autenticato → redirect login" do
      post member_chat_conversations_path, params: { kind: "direct" }
      expect(response).to redirect_to(login_path)
    end

    it "create messaggio non autenticato → redirect login" do
      post member_chat_conversation_messages_path(conversation), params: { body: "x" }
      expect(response).to redirect_to(login_path)
    end

    it "delete messaggio non autenticato → redirect login" do
      delete member_chat_conversation_message_path(conversation, "00000000-0000-0000-0000-000000000000")
      expect(response).to redirect_to(login_path)
    end

    it "mute non autenticato → redirect login" do
      put member_chat_conversation_mute_path(conversation)
      expect(response).to redirect_to(login_path)
    end

    it "taggable non autenticato → redirect login" do
      get taggable_member_chat_conversation_path(conversation)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET index" do
    it "risponde 200" do
      sign_in(member(seeing: [ shared ]))
      get member_chat_conversations_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET index — header e layout due colonne" do
    it "mostra le chip coi conteggi di conversazioni e non letti" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      create(:chat_message, conversation: conversation, author: other)

      sign_in(me)
      get member_chat_conversations_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='chat-count-conversations']").text).to include("1")
      expect(doc.css("[data-test='chat-count-unread']").text).to include("1")
    end

    # CYRA-447 — le due colonne valgono quando c'è qualcosa da elencare: l'invito a scegliere una
    # conversazione ha senso solo se ce n'è almeno una da scegliere.
    it "mostra il pane conversazioni a sinistra e il placeholder del thread a destra" do
      me = member(seeing: [ shared ])
      dm_between(me, member(seeing: [ shared ]))

      sign_in(me)
      get member_chat_conversations_path

      expect(response.body).to include('data-test="chat-conversations-pane"')
      expect(response.body).to include('data-test="chat-thread-placeholder"')
    end

    it "senza conversazioni rende un solo blocco: né la lista né l'invito a sceglierne una" do
      sign_in(member(seeing: [ shared ]))
      get member_chat_conversations_path

      expect(response.body).to include('data-test="chat-empty"')
      expect(response.body).not_to include('data-test="chat-conversations-pane"')
      expect(response.body).not_to include('data-test="chat-thread-placeholder"')
      expect(response.body).not_to include(I18n.t("member.chat.select_conversation"))
    end

    # CYRA-856 — lo stato vuoto insegna in tre parti (cosa manca, a cosa serve, un esempio) e propone
    # una sola strada. Le parole in se' le presidia spec/i18n/chat_empty_wording_spec.rb.
    it "senza conversazioni spiega a cosa servono, porta un esempio e offre una sola azione" do
      sign_in(member(seeing: [ shared ]))
      get member_chat_conversations_path

      vuoto = Nokogiri::HTML(response.body).at_css("[data-test='chat-empty']")
      expect(vuoto.at_css("[data-test='empty-title']").text).to eq(I18n.t("member.chat.empty"))
      expect(vuoto.at_css("[data-test='empty-body']").text).to eq(I18n.t("member.chat.empty_body"))
      expect(vuoto.at_css("[data-test='empty-example']").text).to eq(I18n.t("member.chat.empty_example"))
      expect(vuoto.css("a, button").map { |azione| azione.text.strip })
        .to eq([ I18n.t("member.chat.new_conversation.button") ])
    end

    it "la riga della conversazione porta il badge dei non letti" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      # Setup: la validazione tenant di ogni messaggio fa la stessa membership-check → non è un N+1 di prodotto.
      allow_n_plus_one { create_list(:chat_message, 2, conversation: conversation, author: other) }

      sign_in(me)
      get member_chat_conversations_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='chat-unread-badge-#{conversation.id}']").text).to eq("2")
    end

    it "senza messaggi non letti la riga non mostra badge" do
      me = member(seeing: [ shared ])
      conversation = dm_between(me, member(seeing: [ shared ]))

      sign_in(me)
      get member_chat_conversations_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='chat-unread-badge-#{conversation.id}']")).to be_empty
    end
  end

  describe "GET show — layout due colonne" do
    it "mostra la sidebar con la conversazione attiva marcata" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sibling = dm_between(me, member(seeing: [ shared ]))

      sign_in(me)
      get member_chat_conversation_path(conversation)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='chat-conversations-pane']")).to be_present
      expect(doc.css("[data-test='chat-conversation-link-#{conversation.id}'][aria-current='page']")).to be_present
      expect(doc.css("[data-test='chat-conversation-link-#{sibling.id}'][aria-current='page']")).to be_empty
    end

    it "aprire la conversazione azzera il suo badge non letti (mark_read)" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      create(:chat_message, conversation: conversation, author: other)

      sign_in(me)
      get member_chat_conversation_path(conversation)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='chat-unread-badge-#{conversation.id}']")).to be_empty
    end

    it "il pane destro contiene il thread e il compose (DOM id realtime intatti)" do
      me = member(seeing: [ shared ])
      conversation = dm_between(me, member(seeing: [ shared ]))

      sign_in(me)
      get member_chat_conversation_path(conversation)

      expect(response.body).to include("chat_messages_#{conversation.id}")
      expect(response.body).to include("chat_receipts_#{conversation.id}")
      expect(response.body).to include("chat_typing_#{conversation.id}")
      expect(response.body).to include('data-test="chat-compose-body"')
    end
  end

  describe "GET index — picker nuova conversazione" do
    def picker_options(body, test_id)
      Nokogiri::HTML(body).css("[data-test='#{test_id}'] option").map(&:text)
    end

    it "mostra il bottone e la select DM coi membri dell'org, escluso sé" do
      me = member(seeing: [ shared ]).tap { |a| a.update!(name: "Me Selfname") }
      member(seeing: [ shared ]).tap { |a| a.update!(name: "Other Pickable") }
      sign_in(me)

      get member_chat_conversations_path

      # No conversations yet: the empty state carries the New action, there is no list panel.
      expect(response.body).to include('data-test="chat-empty-new"')
      options = picker_options(response.body, "chat-new-direct-account")
      expect(options).to include("Other Pickable")
      expect(options).not_to include("Me Selfname")
    end

    it "mostra la sezione canale progetto coi progetti visibili" do
      sign_in(member(seeing: [ shared ]))

      get member_chat_conversations_path

      expect(picker_options(response.body, "chat-new-project-select")).to include(shared.name)
    end

    it "mostra la sezione canale team coi team di appartenenza" do
      me = member(seeing: [ shared ])
      team = create(:team, organization: org, name: "Platform Squad")
      create(:team_membership, team: team, account: me)
      sign_in(me)

      get member_chat_conversations_path

      expect(picker_options(response.body, "chat-new-team-select")).to include("Platform Squad")
    end

    it "opens the new conversation dialog in the standard modal shell, with Close in the header (F24)" do
      sign_in(member(seeing: [ shared ]))

      get member_chat_conversations_path

      dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='chat-new-dialog']")
      expect(dialog["class"]).to include("dark:bg-zinc-950")
      expect(dialog.at_css("header [data-test='chat-new-close']")).to be_present
      expect(dialog.css("[data-action~='ui--dialog#close']").size).to eq(1)
    end

    it "senza progetti visibili né team nasconde le sezioni canale ma non il DM" do
      sign_in(member)

      get member_chat_conversations_path

      expect(response.body).not_to include('data-test="chat-new-project-select"')
      expect(response.body).not_to include('data-test="chat-new-team-select"')
      expect(response.body).to include('data-test="chat-new-direct-account"')
    end
  end

  describe "GET show" do
    it "partecipante di un DM → 200" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sign_in(me)
      get member_chat_conversation_path(conversation)
      expect(response).to have_http_status(:ok)
    end

    it "estraneo a un DM altrui → 404 (anti-BOLA)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      outsider = member(seeing: [ shared ])
      sign_in(outsider)
      get member_chat_conversation_path(conversation)
      expect(response).to have_http_status(:not_found)
    end

    it "canale di un progetto non visibile → 404" do
      hidden = create(:project, organization: org)
      channel = Chat::Conversation.create!(organization: org, kind: :project, contextable: hidden)
      sign_in(member(seeing: [ shared ]))
      get member_chat_conversation_path(channel)
      expect(response).to have_http_status(:not_found)
    end

    it "canale di un team a cui non appartengo → 404" do
      team = create(:team, organization: org)
      channel = Chat::Conversation.create!(organization: org, kind: :team, contextable: team)
      sign_in(member(seeing: [ shared ]))
      get member_chat_conversation_path(channel)
      expect(response).to have_http_status(:not_found)
    end

    it "account di un'ALTRA organizzazione → 404 (multi-tenant)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      org_b = create(:organization)
      stranger = member(organization: org_b)
      sign_in(stranger)
      get member_chat_conversation_path(conversation)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create — DM" do
    it "con progetto in comune → apre e reindirizza alla conversazione" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      sign_in(me)
      post member_chat_conversations_path, params: { kind: "direct", account_id: other.id }
      expect(response).to have_http_status(:redirect)
      expect(Chat::Conversation.where(organization: org).kind_direct.count).to eq(1)
    end

    it "doppio POST per la stessa coppia → sempre 1 conversazione (idempotente)" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      sign_in(me)
      post member_chat_conversations_path, params: { kind: "direct", account_id: other.id }
      # Secondo POST (idempotenza): ripete le stesse query per-richiesta della prima — non un N+1 di produzione.
      allow_n_plus_one { post member_chat_conversations_path, params: { kind: "direct", account_id: other.id } }
      expect(Chat::Conversation.where(organization: org).kind_direct.count).to eq(1)
    end

    it "senza progetto in comune → redirect con alert, nessun DM" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ create(:project, organization: org) ])
      sign_in(me)
      post member_chat_conversations_path, params: { kind: "direct", account_id: other.id }
      expect(response).to redirect_to(member_chat_conversations_path)
      expect(Chat::Conversation.kind_direct.count).to eq(0)
    end

    it "DM già esistente si riapre anche se non condividiamo più progetti" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      Connections::ProjectMembership.where(account_id: [ me.id, other.id ], project_id: shared.id).destroy_all
      sign_in(me)
      post member_chat_conversations_path, params: { kind: "direct", account_id: other.id }
      expect(response).to redirect_to(member_chat_conversation_path(conversation))
    end

    it "account_id non membro dell'org → 404" do
      sign_in(member(seeing: [ shared ]))
      post member_chat_conversations_path, params: { kind: "direct", account_id: create(:account).id }
      expect(response).to have_http_status(:not_found)
    end

    it "kind sconosciuto → redirect con alert, nessuna conversazione" do
      sign_in(member(seeing: [ shared ]))
      post member_chat_conversations_path, params: { kind: "bogus" }
      expect(response).to redirect_to(member_chat_conversations_path)
      expect(Chat::Conversation.count).to eq(0)
    end
  end

  describe "POST create — canale di progetto" do
    it "progetto visibile → apre il canale" do
      sign_in(member(seeing: [ shared ]))
      post member_chat_conversations_path, params: { kind: "project", project_id: shared.id }
      expect(response).to have_http_status(:redirect)
      expect(Chat::Conversation.where(organization: org, contextable: shared).count).to eq(1)
    end

    it "progetto non visibile → 404" do
      hidden = create(:project, organization: org)
      sign_in(member(seeing: [ shared ]))
      post member_chat_conversations_path, params: { kind: "project", project_id: hidden.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-856 — il terzo tipo di canale. Il picker lo offre (sopra), il 404 per un team altrui c'e'
  # gia': mancava la prova che aprirlo davvero funzioni, come per DM e progetto.
  describe "POST create — canale di team" do
    it "team di appartenenza → apre il canale" do
      me = member
      team = create(:team, organization: org, name: "Platform Squad")
      create(:team_membership, team: team, account: me)
      sign_in(me)

      post member_chat_conversations_path, params: { kind: "team", team_id: team.id }

      expect(response).to have_http_status(:redirect)
      expect(Chat::Conversation.where(organization: org, contextable: team).count).to eq(1)
    end
  end

  describe "POST messages" do
    it "posta un messaggio nel DM" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sign_in(me)
      expect do
        post member_chat_conversation_messages_path(conversation), params: { body: "ciao" }
      end.to change { conversation.messages.count }.by(1)
      expect(response).to redirect_to(member_chat_conversation_path(conversation))
    end

    it "body vuoto (solo spazi) → redirect con alert, nessun messaggio" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sign_in(me)
      expect do
        post member_chat_conversation_messages_path(conversation), params: { body: "   " }
      end.not_to change { conversation.messages.count }
      expect(flash[:alert]).to be_present
    end

    it "estraneo alla conversazione → 404 e nessun messaggio (anti-BOLA)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      outsider = member(seeing: [ shared ])
      sign_in(outsider)
      expect do
        post member_chat_conversation_messages_path(conversation), params: { body: "intruso" }
      end.not_to change { conversation.messages.count }
      expect(response).to have_http_status(:not_found)
    end

    it "account di un'altra organizzazione → 404 (multi-tenant)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      stranger = member(organization: create(:organization))
      sign_in(stranger)
      post member_chat_conversation_messages_path(conversation), params: { body: "cross" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE message" do
    it "l'autore elimina il proprio (soft delete)" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      message = Chat::PostMessage.call(conversation: conversation, author: me, params: { body: "mio" }).value
      sign_in(me)
      delete member_chat_conversation_message_path(conversation, message)
      expect(message.reload.deleted?).to be(true)
    end

    it "un non-autore senza moderazione → 403 e messaggio intatto" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      message = Chat::PostMessage.call(conversation: conversation, author: other, params: { body: "suo" }).value
      sign_in(me)
      delete member_chat_conversation_message_path(conversation, message)
      expect(response).to redirect_to(member_chat_conversation_path(conversation))
      expect(message.reload.deleted?).to be(false)
    end

    it "estraneo totale alla conversazione → 404 prima del check moderazione" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      message = Chat::PostMessage.call(conversation: conversation, author: a, params: { body: "loro" }).value
      outsider = member(seeing: [ shared ])
      sign_in(outsider)
      delete member_chat_conversation_message_path(conversation, message)
      expect(response).to have_http_status(:not_found)
      expect(message.reload.deleted?).to be(false)
    end

    it "l'owner modera il canale di progetto (elimina altrui)" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      author = member(seeing: [ shared ])
      channel = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: owner).value
      message = Chat::PostMessage.call(conversation: channel, author: author, params: { body: "canale" }).value
      sign_in(owner)
      delete member_chat_conversation_message_path(channel, message), params: { confirm: "1" }
      expect(message.reload.deleted?).to be(true)
    end

    it "un member SENZA chat.moderate nel canale di progetto non elimina l'altrui" do
      author = member(seeing: [ shared ])
      plain = member(seeing: [ shared ])
      channel = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: author).value
      message = Chat::PostMessage.call(conversation: channel, author: author, params: { body: "del canale" }).value
      sign_in(plain)
      delete member_chat_conversation_message_path(channel, message)
      expect(response).to redirect_to(member_chat_conversation_path(channel))
      expect(message.reload.deleted?).to be(false)
    end
  end

  describe "mute / unmute" do
    it "silenzia e riattiva la conversazione" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sign_in(me)

      put member_chat_conversation_mute_path(conversation)
      participant = conversation.participants.find_by(account_id: me.id)
      expect(participant.reload.muted?).to be(true)

      delete member_chat_conversation_mute_path(conversation)
      expect(participant.reload.muted?).to be(false)
    end

    it "doppio mute → resta silenziata senza errori (idempotente)" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      sign_in(me)
      put member_chat_conversation_mute_path(conversation)
      # Secondo mute (idempotenza): ripete le query per-richiesta della prima — non un N+1 di produzione.
      allow_n_plus_one { put member_chat_conversation_mute_path(conversation) }
      expect(conversation.participants.find_by(account_id: me.id).muted?).to be(true)
    end

    it "estraneo alla conversazione → 404 (anti-BOLA)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      outsider = member(seeing: [ shared ])
      sign_in(outsider)
      put member_chat_conversation_mute_path(conversation)
      expect(response).to have_http_status(:not_found)
      expect(conversation.participants.where(account_id: outsider.id)).to be_empty
    end
  end

  describe "GET taggable" do
    it "restituisce solo risorse nell'intersezione dei partecipanti" do
      me = member(seeing: [ shared ])
      only_me = create(:project, organization: org)
      create(:project_membership, account: me, project: only_me)
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)

      common_ticket = create(:ticket, organization: org, project: shared, title: "Comune")
      private_ticket = create(:ticket, organization: org, project: only_me, title: "Privato")

      sign_in(me)
      get taggable_member_chat_conversation_path(conversation), params: { q: "" }
      ids = response.parsed_body["data"].map { |entry| entry["id"] }
      expect(ids).to include(common_ticket.id)
      expect(ids).not_to include(private_ticket.id)
    end

    it "estraneo alla conversazione → 404 (anti-BOLA)" do
      a = member(seeing: [ shared ])
      b = member(seeing: [ shared ])
      conversation = dm_between(a, b)
      outsider = member(seeing: [ shared ])
      sign_in(outsider)
      get taggable_member_chat_conversation_path(conversation), params: { q: "" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "riferimenti e revoca accesso (leak reference)" do
    it "il viewer che ha PERSO il progetto vede il placeholder, non i dati del ticket" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      ticket = create(:ticket, organization: org, project: shared, title: "Segreto industriale")
      code = "#{shared.key}-#{ticket.number}"
      Chat::PostMessage.call(conversation: conversation, author: other, params: { body: "guarda ##{code}" }).value

      # Revoca live: il viewer perde il progetto del ticket taggato.
      Connections::ProjectMembership.where(account_id: me.id, project_id: shared.id).destroy_all

      sign_in(me)
      get member_chat_conversation_path(conversation)
      expect(response).to have_http_status(:ok)
      # Placeholder al posto della card: niente link al ticket né card completa (il body del
      # messaggio conserva il testo digitato, che è dell'utente — non è il leak).
      expect(response.body).to include("chat-reference-unavailable")
      expect(response.body).not_to include(%(data-test="chat-reference-card"))
      expect(response.body).not_to include("/member/tickets/#{ticket.id}")
    end

    it "il partecipante che vede ancora il progetto vede la card completa" do
      me = member(seeing: [ shared ])
      other = member(seeing: [ shared ])
      conversation = dm_between(me, other)
      ticket = create(:ticket, organization: org, project: shared, title: "Visibile")
      code = "#{shared.key}-#{ticket.number}"
      Chat::PostMessage.call(conversation: conversation, author: other, params: { body: "guarda ##{code}" }).value

      sign_in(me)
      get member_chat_conversation_path(conversation)
      expect(response.body).to include("chat-reference-card")
      expect(response.body).to include(code)
    end
  end

  # Page refactor (2026-10-01): same shape as the other refactored pages.
  describe "page layout" do
    def html
      Capybara.string(response.body)
    end

    let(:me) { member(seeing: [ shared ]) }
    let(:other) { member(seeing: [ shared ]) }

    describe "list" do
      it "has a one-line subtitle" do
        sign_in(me)
        get member_chat_conversations_path

        expect(response.body).to include(I18n.t("member.chat.subtitle"))
      end

      it "filters the list to unread conversations from the Unread chip" do
        unread = dm_between(me, other)
        create(:chat_message, conversation: unread, author: other)
        read = Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: shared, actor: me).value
        sign_in(me)

        get member_chat_conversations_path
        chip = html.find("a[data-test='chat-count-unread']")

        get chip[:href]
        expect(html).to have_css("[data-test='chat-conversation-link-#{unread.id}']")
        expect(html).to have_no_css("[data-test='chat-conversation-link-#{read.id}']")
      end

      it "puts a search field above the list" do
        dm_between(me, other)
        sign_in(me)
        get member_chat_conversations_path

        expect(html).to have_css("[data-test='chat-conversations-pane'] [data-test='chat-pane-search']")
      end

      it "shows the last message under the name and an icon for the kind" do
        conversation = dm_between(me, other)
        create(:chat_message, conversation: conversation, author: other, body: "I will look after lunch")
        sign_in(me)
        get member_chat_conversations_path

        row = html.find("[data-test='chat-conversation-link-#{conversation.id}']")
        expect(row).to have_css("[data-test='chat-conversation-preview']", text: "I will look after lunch")
        expect(row).to have_css("[data-test='chat-kind-icon'][title='#{I18n.t("member.chat.kinds.direct")}']")
      end

      it "keeps the empty state to one sentence and moves the ticket-comment advice to the subtitle" do
        sign_in(me)
        get member_chat_conversations_path

        expect(html.find("[data-test='chat-empty'] [data-test='empty-body']").text).not_to match(/commento|comment/i)
        expect(response.body).to include(I18n.t("member.chat.subtitle"))
      end

      it "keeps counting every conversation while the Unread chip is on" do
        dm_between(me, other)
        sign_in(me)
        get member_chat_conversations_path(unread: 1)

        expect(html.find("[data-test='chat-count-conversations']")).to have_text("1")
      end

      it "shows the empty state, not the pick-one prompt, when Unread is on and there are no conversations" do
        sign_in(me)
        get member_chat_conversations_path(unread: 1)

        expect(html).to have_css("[data-test='chat-empty']")
        expect(html).to have_no_css("[data-test='chat-thread-placeholder']")
      end

      it "turns the Unread chip off again from the filtered list" do
        dm_between(me, other)
        sign_in(me)
        get member_chat_conversations_path(unread: 1)

        chip = html.find("a[data-test='chat-count-unread']")
        expect(chip[:href]).to eq(member_chat_conversations_path)
      end
    end

    describe "thread" do
      let(:conversation) { dm_between(me, other) }

      before do
        allow_n_plus_one do
          create(:chat_message, conversation: conversation, author: other, body: "Yesterday's note", created_at: 1.day.ago)
          create(:chat_message, conversation: conversation, author: me, body: "Today's answer")
        end
        sign_in(me)
        get member_chat_conversation_path(conversation)
      end

      it "says the kind and how many people are in it" do
        expect(html).to have_css("[data-test='chat-thread-meta']", text: I18n.t("member.chat.kinds.direct"))
        expect(html).to have_css("[data-test='chat-thread-meta']", text: I18n.t("member.chat.people", count: 2))
      end

      it "renders Mute as a design system button with a bell" do
        expect(html).to have_css("[data-test='chat-mute'] svg[data-icon='bell-off']", visible: :all)
      end

      it "shows the time of each message and a separator for each day" do
        expect(html).to have_css("[data-test='chat-message-time']", count: 2)
        expect(html.all("[data-test='chat-day']").map(&:text).map(&:strip))
          .to eq([ I18n.t("member.chat.days.yesterday"), I18n.t("member.chat.days.today") ])
      end

      it "marks each message with its author so the browser can put mine on the right" do
        expect(html).to have_css("[data-test='chat-message'][data-author-id='#{me.id}']")
      end

      it "asks before deleting a message" do
        expect(html).to have_css("[data-test^='chat-message-delete-'][data-turbo-confirm]")
      end

      it "puts Send in the composer with the keys hint" do
        expect(html).to have_css("[data-test='chat-compose'] [data-test='chat-compose-hint']",
                                 text: I18n.t("member.chat.compose_hint"))
      end
    end
  end
end
