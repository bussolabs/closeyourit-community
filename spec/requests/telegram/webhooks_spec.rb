# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telegram webhook", type: :request do
  let(:secret) { "s3cr3t-webhook" }
  let(:account) { create(:account) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_WEBHOOK_SECRET").and_return(secret)
  end

  def post_update(message, header_secret: secret)
    post "/telegram/webhook",
         params: { message: message }.to_json,
         headers: { "Content-Type" => "application/json", "X-Telegram-Bot-Api-Secret-Token" => header_secret }
  end

  describe "POST /telegram/webhook" do
    it "header secret errato → 404 (endpoint nascosto agli scanner)" do
      post_update({ text: "/start x", chat: { id: 111 } }, header_secret: "wrong")
      expect(response).to have_http_status(:not_found)
    end

    it "header secret assente → 404" do
      post "/telegram/webhook", params: { message: { text: "/start x", chat: { id: 111 } } }.to_json,
                                headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:not_found)
    end

    it "/start <codice valido> collega chat_id e username all'account (e consuma il codice)" do
      code = Accounts::TelegramLinkCode.issue(account: account)

      post_update({ text: "/start #{code}", chat: { id: 424_242, username: "mario" } })

      expect(response).to have_http_status(:ok)
      expect(account.reload.telegram_chat_id).to eq("424242")
      expect(account.telegram_username).to eq("mario")
      expect(account.telegram_linked_at).to be_present
      expect(Accounts::TelegramLinkCode.where(code: code)).to be_empty # single-use
    end

    it "/start con codice invalido non collega nulla (200, niente retry di Telegram)" do
      post_update({ text: "/start not-a-real-code", chat: { id: 999 } })

      expect(response).to have_http_status(:ok)
      expect(Accounts::Account.where(telegram_chat_id: "999")).to be_empty
    end

    it "un chat_id già legato altrove viene spostato al nuovo account (un chat_id = un account)" do
      other = create(:account, telegram_chat_id: "700", telegram_linked_at: Time.current)
      code = Accounts::TelegramLinkCode.issue(account: account)

      post_update({ text: "/start #{code}", chat: { id: 700 } })

      expect(account.reload.telegram_chat_id).to eq("700")
      expect(other.reload.telegram_chat_id).to be_nil
    end

    it "/stop scollega il chat_id dell'account che lo possiede" do
      account.update!(telegram_chat_id: "555", telegram_linked_at: Time.current)

      post_update({ text: "/stop", chat: { id: 555 } })

      expect(response).to have_http_status(:ok)
      expect(account.reload.telegram_chat_id).to be_nil
    end

    it "un messaggio non-comando è ignorato (200, nessun effetto)" do
      post_update({ text: "ciao", chat: { id: 777 } })

      expect(response).to have_http_status(:ok)
      expect(Accounts::Account.where(telegram_chat_id: "777")).to be_empty
    end

    describe "consegne malformate (il webhook non deve andare in errore)" do
      it "il messaggio non è un oggetto → 200, nessun effetto" do
        post_update("ciao")

        expect(response).to have_http_status(:ok)
      end

      it "la chat non è un oggetto → 200, nessun effetto" do
        post_update({ text: "/aiuto", chat: "111" })

        expect(response).to have_http_status(:ok)
      end

      it "il mittente non è un oggetto → 200, nessun effetto" do
        code = Accounts::TelegramLinkCode.issue(account: account)

        post_update({ text: "/start #{code}", chat: { id: 321 }, from: "mario" })

        expect(response).to have_http_status(:ok)
        expect(account.reload.telegram_chat_id).to eq("321")
      end

      it "la foto non è una lista di file → 200, nessun effetto" do
        post_update({ caption: "/aiuto", chat: { id: 222 }, photo: "non-una-lista" })

        expect(response).to have_http_status(:ok)
      end

      it "il documento non è un oggetto → 200, nessun effetto" do
        post_update({ caption: "/aiuto", chat: { id: 223 }, document: "non-un-oggetto" })

        expect(response).to have_http_status(:ok)
      end

      # Il filtro dei campi controlla i NOMI, non la forma: `permit(chat: [:id])` accetta anche una
      # LISTA di oggetti al posto dell'oggetto, e quella lista arriverebbe intera ai comandi facendo
      # sollevare `dig` come prima del filtro. Serve quindi anche la forma.
      it "la chat è una lista invece di un oggetto → 200, nessun effetto" do
        post_update({ text: "/aiuto", chat: [ { id: 111 } ] })

        expect(response).to have_http_status(:ok)
      end

      it "il mittente è una lista invece di un oggetto → 200, nessun effetto" do
        post_update({ text: "/aiuto", chat: { id: 112 }, from: [ { username: "mario" } ] })

        expect(response).to have_http_status(:ok)
      end

      it "foto e documento nella forma sbagliata non arrivano ai comandi" do
        allow(Telegram::HandleUpdate).to receive(:call).and_return(Result.ok(:ignored))

        post_update({ caption: "/aiuto", chat: { id: 113 },
                      photo: { file_id: "AAA" }, document: [ { file_id: "BBB" } ] })

        expect(Telegram::HandleUpdate).to have_received(:call) do |update:|
          message = update.with_indifferent_access[:message]
          expect(message.keys).to match_array(%w[caption chat])
        end
        expect(response).to have_http_status(:ok)
      end

      it "nella lista delle foto entra solo ciò che è un file" do
        allow(Telegram::HandleUpdate).to receive(:call).and_return(Result.ok(:ignored))

        post_update({ caption: "/aiuto", chat: { id: 114 }, photo: [ "AAA", { file_id: "BBB" } ] })

        expect(Telegram::HandleUpdate).to have_received(:call) do |update:|
          expect(update.with_indifferent_access.dig(:message, :photo)).to eq([ { "file_id" => "BBB" } ])
        end
        expect(response).to have_http_status(:ok)
      end

      it "il corpo non è JSON → consegna lasciata cadere, nessun errore del server" do
        expect(Telegram::HandleUpdate).not_to receive(:call)

        post "/telegram/webhook", params: "{non-json",
                                  headers: { "Content-Type" => "application/json",
                                             "X-Telegram-Bot-Api-Secret-Token" => secret }

        expect(response).to have_http_status(:ok)
      end
    end

    it "al programma arrivano SOLO i campi previsti (il resto della consegna è scartato)" do
      allow(Telegram::HandleUpdate).to receive(:call).and_return(Result.ok(:ignored))

      post_update({
                    text: "/aiuto", caption: "didascalia",
                    chat: { id: 111, username: "mario", type: "private" },
                    from: { username: "mario", id: 42 },
                    photo: [ { file_id: "AAA", file_size: 100 } ],
                    document: { file_id: "BBB", file_name: "log.txt", mime_type: "text/plain" },
                    entities: [ { type: "bot_command" } ]
                  })

      expect(Telegram::HandleUpdate).to have_received(:call) do |update:|
        message = update.with_indifferent_access[:message]
        expect(message.keys).to match_array(%w[text caption chat from photo document])
        expect(message[:chat]).to eq("id" => 111, "username" => "mario", "type" => "private")
        expect(message[:from]).to eq("username" => "mario")
        expect(message[:photo]).to eq([ { "file_id" => "AAA" } ])
        expect(message[:document]).to eq("file_id" => "BBB", "file_name" => "log.txt")
      end
      expect(response).to have_http_status(:ok)
    end

    it "/start senza token → risponde con la guida al collegamento (il bot non resta muto)" do
      expect(Telegram::Send).to receive(:call)
        .with(chat_id: 888, text: I18n.t("telegram.start.welcome", locale: I18n.default_locale))
        .and_return(Result.ok(true))

      post_update({ text: "/start", chat: { id: 888 } })

      expect(response).to have_http_status(:ok)
      expect(Accounts::Account.where(telegram_chat_id: "888")).to be_empty
    end
  end

  # CYRA-852 — in un gruppo il bot ascolta solo il collegamento del gruppo con argomenti.
  describe "messaggi da un gruppo" do
    let(:organization) { create(:organization) }

    before do
      create(:membership, account: account, organization: organization, role: :owner)
      stub_request(:post, %r{api.telegram.org/.*/sendMessage}).to_return(status: 200)
    end

    it "/start@bot CODICE in un gruppo con argomenti lo collega all'organizzazione" do
      code = Accounts::TelegramLinkCode.issue(account: account, organization: organization)

      post_update({ text: "/start@closeyourit_bot #{code}",
                    chat: { id: -100_555, type: "supergroup", title: "Avvisi", is_forum: true } })

      expect(response).to have_http_status(:ok)
      expect(Alerting::TelegramGroup.find_by(organization: organization)).to have_attributes(chat_id: "-100555", title: "Avvisi")
      expect(account.reload.telegram_chat_id).to be_nil
    end

    it "gli altri comandi nel gruppo sono ignorati" do
      post_update({ text: "/aiuto", chat: { id: -100_555, type: "supergroup" } })

      expect(response).to have_http_status(:ok)
      expect(a_request(:post, %r{sendMessage})).not_to have_been_made
    end
  end
end
