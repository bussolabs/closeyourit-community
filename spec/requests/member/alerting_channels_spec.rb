# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::AlertingChannels", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login" do
    get member_alerting_channels_path
    expect(response).to redirect_to(login_path)
  end

  # B20 — channels sit beside the rules in the sidebar, so the rules are not a level of the path.
  it "names the area and the page in the breadcrumb, not the rules page" do
    sign_in(owner)
    get member_alerting_channels_path

    crumbs = Capybara.string(response.body).all("[data-test='breadcrumb-crumb']").map(&:text)
    expect(crumbs.last).to eq(I18n.t("member.alerting.channels.title"))
    expect(crumbs).not_to include(I18n.t("member.alerting.rules.title"))
  end

  it "member senza alerts.manage → redirect (forbidden)" do
    sign_in(member)
    get member_alerting_channels_path
    expect(response).to redirect_to(root_path)
  end

  context "owner" do
    before { sign_in(owner) }

    it "index elenca i canali dell'org (e non quelli altrui)" do
      mine = create(:alerting_channel, organization: org, name: "Ops webhook")
      foreign = create(:alerting_channel)

      get member_alerting_channels_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(mine.name))
      expect(response.body).not_to include(foreign.id)
    end

    it "new → 200" do
      get new_member_alerting_channel_path
      expect(response).to have_http_status(:ok)
    end

    it "l'intestazione Status non è un <label> orfano (a11y: label sempre associato a un controllo)" do
      get new_member_alerting_channel_path
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("label").map { |l| l.text.strip }).not_to include(I18n.t("member.alerting.channels.form.status"))
      expect(doc.css("p").map { |p| p.text.strip }).to include(I18n.t("member.alerting.channels.form.status"))
    end

    it "create webhook coi params esatti del form" do
      expect do
        post member_alerting_channels_path, params: {
          name: "Ops", kind: "webhook", enabled: "1",
          webhook_url: "https://hooks.example.test/cyi", webhook_secret: "s3"
        }
      end.to change(org.alerting_channels, :count).by(1)

      channel = org.alerting_channels.last
      expect(channel.webhook_url).to eq("https://hooks.example.test/cyi")
      expect(channel.webhook_secret).to eq("s3")
      expect(channel.created_by).to eq(owner)
      expect(response).to redirect_to(member_alerting_channels_path)
    end

    it "create invalido (URL interna) → 422 col form rirenderizzato" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "127.0.0.1" ])

      post member_alerting_channels_path, params: {
        name: "Bad", kind: "webhook", enabled: "1", webhook_url: "https://interno.test/x"
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "update con webhook_secret vuoto preserva il secret esistente (non lo azzera)" do
      channel = create(:alerting_channel, organization: org, webhook_secret: "keep-me")

      patch member_alerting_channel_path(channel), params: {
        name: "Rinominato", kind: "webhook", enabled: "0",
        webhook_url: "https://hooks.example.test/v2", webhook_secret: ""
      }

      channel.reload
      expect(channel.name).to eq("Rinominato")
      expect(channel.webhook_url).to eq("https://hooks.example.test/v2")
      expect(channel.webhook_secret).to eq("keep-me")
      expect(channel).not_to be_enabled
    end

    it "update con nuovo webhook_secret lo sostituisce" do
      channel = create(:alerting_channel, organization: org, webhook_secret: "old")

      patch member_alerting_channel_path(channel), params: {
        name: channel.name, kind: "webhook", enabled: "1",
        webhook_url: channel.webhook_url, webhook_secret: "new-secret"
      }

      expect(channel.reload.webhook_secret).to eq("new-secret")
    end

    it "il form edit non riespone il secret nell'HTML (campo password vuoto)" do
      channel = create(:alerting_channel, organization: org, webhook_secret: "top-secret-value")

      get edit_member_alerting_channel_path(channel)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("top-secret-value")
      field = Nokogiri::HTML(response.body).at_css("[data-test='alerting-channel-webhook-secret']")
      expect(field[:type]).to eq("password")
      expect(field[:value].to_s).to eq("")
    end

    it "edit/update/destroy su canale di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:alerting_channel)

      get edit_member_alerting_channel_path(foreign)
      expect(response).to have_http_status(:not_found)

      delete member_alerting_channel_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "destroy elimina il canale e i collegamenti alle regole" do
      channel = create(:alerting_channel, organization: org)
      rule = create(:alerting_rule, organization: org)
      create(:alerting_rule_channel, rule:, channel:)

      expect { delete member_alerting_channel_path(channel) }
        .to change(org.alerting_channels, :count).by(-1)
        .and change(Alerting::RuleChannel, :count).by(-1)
      expect(rule.reload).to be_persisted
    end

    it "la regola aggancia i canali via channel_ids (SET, scoped org)" do
      channel = create(:alerting_channel, organization: org)
      foreign = create(:alerting_channel)

      post member_alerting_rules_path, params: {
        name: "Con canale", event_type: "error_new", throttle_minutes: 5, enabled: "1",
        channel_ids: [ channel.id, foreign.id ]
      }

      rule = org.alerting_rules.find_by!(name: "Con canale")
      expect(rule.channels).to contain_exactly(channel)
    end

    # CYRA-496 — la pagina dei canali era l'unica dell'area senza titolo nella scheda del browser:
    # con più schede aperte si leggeva «CloseYourIt» secco e non si riconosceva. Le altre seguono
    # tutte lo schema «Nome pagina · CloseYourIt».
    describe "il titolo nella scheda del browser (CYRA-496)" do
      def titolo(body) = Nokogiri::HTML(body).at_css("title").text

      it "l'elenco dei canali si intitola come la pagina" do
        get member_alerting_channels_path

        expect(titolo(response.body)).to eq("#{I18n.t('member.alerting.channels.title')} · CloseYourIt")
      end

      it "il form di creazione dice che si sta creando un canale" do
        get new_member_alerting_channel_path

        expect(titolo(response.body)).to eq("#{I18n.t('member.alerting.channels.new_title')} · CloseYourIt")
      end

      it "il form di modifica dice che si sta modificando un canale" do
        channel = create(:alerting_channel, organization: org)

        get edit_member_alerting_channel_path(channel)

        expect(titolo(response.body)).to eq("#{I18n.t('member.alerting.channels.edit_title')} · CloseYourIt")
      end
    end

    # CYRA-496 — la voce nel menu laterale: la pagina si raggiungeva solo dal bottone in cima alle
    # regole, quindi la si trovava per caso.
    it "il menu laterale porta ai canali di consegna, col nome della pagina" do
      get member_alerting_channels_path

      expect(response.body).to include(%(href="#{member_alerting_channels_path}"))
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.nav.alert_channels")))
    end

    # CYRA-26: the form note (at the bottom, hand-drawn with an info icon) moved into the
    # bulb title_tip next to the form title.
    # CYRA-883 — the form note is the header subtitle.
    it "shows the form note as the header subtitle" do
      get new_member_alerting_channel_path
      subtitle = Nokogiri::HTML(response.body).at_css("[data-test='alerting-channel-header-subtitle']")
      expect(subtitle.text).to include(I18n.t("member.alerting.channels.form.note"))
    end

    it "no longer draws the hand-made info note at the bottom of the form" do
      get new_member_alerting_channel_path
      expect(Nokogiri::HTML(response.body).css("svg[data-icon='info']")).to be_empty
    end

    it "sotto il titolo i conteggi dei canali: totale e attivi" do
      create(:alerting_channel, organization: org, enabled: true)
      create(:alerting_channel, organization: org, enabled: false)

      get member_alerting_channels_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-channels-count-total']").text).to include("2")
      expect(doc.at_css("[data-test='alerting-channels-count-enabled']").text).to include("1")
    end

    it "l'elenco vuoto non promette canali Telegram: Telegram si collega dalle preferenze" do
      get member_alerting_channels_path

      empty = Nokogiri::HTML(response.body).at_css("[data-test='alerting-channels-empty']").text
      expect(empty).not_to match(/webhook (o|or) Telegram/i)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      channel = create(:alerting_channel, organization: org, name: "Ops webhook")

      get member_alerting_channels_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='alerting-channel-delete-dialog-#{channel.id}']")
      expect(dialog.text).to include(I18n.t("member.alerting.channels.delete_dialog.title", name: "Ops webhook"))
      expect(dialog.at_css("form")["action"]).to eq(member_alerting_channel_path(channel))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='alerting-channel-delete-#{channel.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
