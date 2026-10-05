# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::AlertingNotifications", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account: account, organization: organization, role: :member) }

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  def own_notification(**attrs)
    create(:alerting_notification, { organization: organization, account: account, via: :in_app }.merge(attrs))
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_alerting_notifications_path
      expect(response).to redirect_to(login_path)
    end

    # B20 — notifications sit beside the rules in the sidebar, so the rules are not a level of the path.
    it "names the area and the page in the breadcrumb, not the rules page" do
      sign_in(account)
      get member_alerting_notifications_path

      crumbs = Capybara.string(response.body).all("[data-test='breadcrumb-crumb']").map(&:text)
      expect(crumbs.last).to eq(I18n.t("member.alerting.notifications.title"))
      expect(crumbs).not_to include(I18n.t("member.alerting.rules.title"))
    end

    # F115 — a down alert names its recovery, so the two rows read as one story.
    it "says on a down alert when the same thing came back" do
      host = create(:server_host, organization:)
      down = own_notification(event_type: :server_down, subject: host, created_at: 40.minutes.ago)
      own_notification(event_type: :server_up, subject: host, created_at: 28.minutes.ago)
      still_down = own_notification(event_type: :server_down, subject: create(:server_host, organization:), created_at: 10.minutes.ago)
      sign_in(account)

      get member_alerting_notifications_path

      html = Capybara.string(response.body)
      expect(html.find("##{ActionView::RecordIdentifier.dom_id(down)} [data-test='notification-recovered']").text).to eq("back after 12 minutes")
      expect(html).to have_no_css("##{ActionView::RecordIdentifier.dom_id(still_down)} [data-test='notification-recovered']")
    end

    it "il membro vede le proprie notifiche (non gated da alerts.manage)" do
      sign_in(account)
      own_notification(title: "New error · Boom")
      get member_alerting_notifications_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New error · Boom")
    end

    it "non mostra le notifiche di un altro account" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: organization, role: :member)
      create(:alerting_notification, organization: organization, account: other, via: :in_app, title: "Altrui")
      get member_alerting_notifications_path
      expect(response.body).not_to include("Altrui")
    end

    it "mostra anche le notifiche già lette (riga in stato letto)" do
      sign_in(account)
      own_notification(read_at: 1.hour.ago, title: "Gia letta")
      get member_alerting_notifications_path
      expect(response.body).to include("Gia letta")
    end

    it "con ore silenziose configurate, l'header le segnala con l'orario (CYRA-479)" do
      sign_in(account)
      create(:alerting_preference, account: account, organization: organization,
             quiet_hours_start: 22, quiet_hours_end: 7, quiet_hours_tz: "Europe/Rome")
      get member_alerting_notifications_path
      badge = Nokogiri::HTML(response.body).at_css("[data-test='notifications-quiet-hours']")
      expect(badge).to be_present
      expect(badge.text).to include("22:00")
      expect(badge.text).to include("07:00")
    end

    it "senza ore silenziose, nessun indicatore nell'header (CYRA-479)" do
      sign_in(account)
      get member_alerting_notifications_path
      expect(Nokogiri::HTML(response.body).at_css("[data-test='notifications-quiet-hours']")).to be_nil
    end


    # CYRA-323: avvisi identici ravvicinati → una riga con badge "×N", non N righe ripetute.
    it "raggruppa avvisi identici ravvicinati in una riga col badge di ripetizione" do
      sign_in(account)
      host = create(:server_host, organization: organization)
      3.times { |n| own_notification(title: "Contenitore caduto · apps", body: "27 container caduti su apps.",
                                      subject: host, created_at: (n * 10).minutes.ago) }
      get member_alerting_notifications_path
      expect(response.body.scan("Contenitore caduto · apps").size).to eq(1)
      expect(response.body).to include("×3")
    end

    it "un avviso mai ripetuto non mostra alcun badge" do
      sign_in(account)
      own_notification(title: "Contenitore caduto · apps", body: "27 container caduti su apps.")
      get member_alerting_notifications_path
      expect(response.body).not_to include("notification-repeat-badge")
    end

    it "l'elenco completo dell'avviso resta consultabile aprendo i dettagli" do
      sign_in(account)
      own_notification(title: "Contenitore caduto · apps", body: "2 container caduti su apps.",
                        details: %w[redis memcached])
      get member_alerting_notifications_path
      expect(response.body).to include("redis").and include("memcached")
    end

    it "distingue una conversazione (ticket) da un avviso tecnico senza leggere il corpo" do
      sign_in(account)
      own_notification(title: "Nuovo commento", event_type: :ticket_commented)
      get member_alerting_notifications_path
      expect(response.body).to include("notification-conversation-tag")
    end

    # CYRA-488 — Scenario 1: separare gli avvisi dei sistemi dai messaggi sui ticket (e dagli agenti).
    describe "separazione per natura (CYRA-488)" do
      it "il filtro 'tickets' mostra i ticket e nasconde gli avvisi di sistema" do
        sign_in(account)
        own_notification(title: "Server giù · web-1", event_type: :server_down)
        own_notification(title: "Revisione richiesta · CYRA-1", event_type: :ticket_review_requested)
        get member_alerting_notifications_path(nature: "tickets")
        expect(response.body).to include("Revisione richiesta · CYRA-1")
        expect(response.body).not_to include("Server giù · web-1")
      end

      it "il filtro 'systems' mostra gli avvisi di sistema e nasconde i ticket" do
        sign_in(account)
        own_notification(title: "Server giù · web-1", event_type: :server_down)
        own_notification(title: "Revisione richiesta · CYRA-1", event_type: :ticket_review_requested)
        get member_alerting_notifications_path(nature: "systems")
        expect(response.body).to include("Server giù · web-1")
        expect(response.body).not_to include("Revisione richiesta · CYRA-1")
      end

      it "una natura inventata vale come nessun filtro (mostra tutto)" do
        sign_in(account)
        own_notification(title: "Server giù · web-1", event_type: :server_down)
        own_notification(title: "Revisione richiesta · CYRA-1", event_type: :ticket_review_requested)
        get member_alerting_notifications_path(nature: "bogus")
        expect(response.body).to include("Server giù · web-1").and include("Revisione richiesta · CYRA-1")
      end

      # DoD: ogni gruppo mostra il proprio numero di non lette.
      it "ogni scheda mostra il numero di non lette della sua natura" do
        sign_in(account)
        2.times { |n| own_notification(read_at: nil, event_type: :server_down, title: "Server giù #{n}") }
        own_notification(read_at: nil, event_type: :ticket_review_requested, title: "Revisione")
        get member_alerting_notifications_path
        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-test='nature-systems-unread']").text).to include("2")
        expect(doc.at_css("[data-test='nature-tickets-unread']").text).to include("1")
      end

      # T1 — nothing outside panels: the nature tabs are the page header's tabs.
      it "puts the nature tabs in the page header" do
        sign_in(account)
        own_notification(read_at: nil, event_type: :server_down, title: "Server down")
        get member_alerting_notifications_path
        header = Nokogiri::HTML(response.body).at_css("header[data-controller~='ui--page-header']")
        expect(header.at_css("[data-test='notifications-nature-all']")).to be_present
        expect(header.at_css("[data-test='nature-systems-unread']").text).to include("1")
      end
    end

    # CYRA-315 — chi arriva dalla Home deve ritrovare lo stesso elenco e lo stesso numero. Prima il
    # filtro per tipo passava dalla regola che aveva prodotto l'avviso: i commenti e le menzioni non
    # hanno regola, quindi filtrarli dava sempre zero risultati.
    describe "filtro per tipo di notifica (CYRA-315)" do
      it "filtra sul tipo della notifica, anche per i tipi che non nascono da una regola" do
        sign_in(account)
        own_notification(title: "Ti hanno menzionato", event_type: :ticket_mentioned)
        own_notification(title: "Nuovo commento", event_type: :ticket_commented)
        own_notification(title: "Server giù · web-1", event_type: :server_down)

        get member_alerting_notifications_path(event_type: %w[ticket_mentioned])

        expect(response.body).to include("Ti hanno menzionato")
        expect(response.body).not_to include("Nuovo commento")
        expect(response.body).not_to include("Server giù · web-1")
      end

      it "un tipo inventato vale come nessun filtro (mostra tutto)" do
        sign_in(account)
        own_notification(title: "Server giù · web-1", event_type: :server_down)

        get member_alerting_notifications_path(event_type: %w[bogus_event])

        expect(response.body).to include("Server giù · web-1")
      end

      it "il tipo si può scegliere anche fra quelli conversazionali" do
        sign_in(account)

        get member_alerting_notifications_path

        opzioni = Nokogiri::HTML(response.body).css("[data-test='notifications-filter-event'] option")
                                               .map { |option| option["value"] }
        expect(opzioni).to include(*Notifications::Catalog.conversation_event_types)
      end
    end

    # CYRA-315 — il numero in cima dichiarava sempre il totale di tutte le notifiche: chi arrivava
    # dalla Home leggeva 185 di là e un numero completamente diverso di qua, e smetteva di fidarsi.
    describe "il numero in cima è quello di ciò che stai guardando (CYRA-315)" do
      before do
        sign_in(account)
        2.times { |n| own_notification(read_at: nil, event_type: :server_down, title: "Server giù #{n}") }
        own_notification(read_at: nil, event_type: :ticket_mentioned, title: "Menzione")
        own_notification(read_at: 1.hour.ago, event_type: :ticket_mentioned, title: "Menzione letta")
      end

      def numero_in_cima
        Nokogiri::HTML(response.body).at_css("[data-test='notifications-unread-count']").text.strip
      end

      it "senza filtri resta il totale delle non lette" do
        get member_alerting_notifications_path

        expect(numero_in_cima).to eq("3")
      end

      it "con una natura scelta conta le non lette di quella natura" do
        get member_alerting_notifications_path(nature: "systems", read: "unread")

        expect(numero_in_cima).to eq("2")
      end

      it "con un tipo scelto conta le non lette di quel tipo" do
        get member_alerting_notifications_path(event_type: %w[ticket_mentioned], read: "unread")

        expect(numero_in_cima).to eq("1")
      end

      it "le schede seguono lo stesso taglio: nessun secondo numero che contraddice il primo" do
        get member_alerting_notifications_path(event_type: %w[ticket_mentioned])

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-test='nature-tickets-unread']").text).to include("1")
        expect(doc.at_css("[data-test='nature-systems-unread']")).to be_nil
      end
    end

    # CYRA-488 — Scenario 2: riconoscere la gravità senza leggerle tutte.
    describe "gravità visiva (CYRA-488)" do
      it "una caduta di produzione porta il marcatore di gravità" do
        sign_in(account)
        own_notification(title: "Server giù · web-1", event_type: :server_down)
        get member_alerting_notifications_path
        expect(Nokogiri::HTML(response.body).at_css("[data-test='notification-critical']")).to be_present
      end

      it "un avviso minore non porta il marcatore di gravità" do
        sign_in(account)
        own_notification(title: "Uptime ripristinato", event_type: :uptime_up)
        get member_alerting_notifications_path
        expect(Nokogiri::HTML(response.body).at_css("[data-test='notification-critical']")).to be_nil
      end
    end

    # CYRA-488 — DoD: accanto all'icona un'etichetta scritta che dichiara il tipo.
    it "ogni riga porta l'etichetta scritta del tipo accanto all'icona" do
      sign_in(account)
      own_notification(title: "Server giù · web-1", event_type: :server_down)
      get member_alerting_notifications_path
      label = Nokogiri::HTML(response.body).at_css("[data-test='notification-type-label']")
      expect(label).to be_present
      expect(label.text.strip).to eq(I18n.t("member.notifications.catalog.server_down.title"))
    end
  end

  describe "PATCH read" do
    it "segna come letta la propria notifica" do
      sign_in(account)
      notification = own_notification(read_at: nil)
      patch read_member_alerting_notification_path(notification)
      expect(notification.reload).to be_read
      expect(response).to redirect_to(member_alerting_notifications_path)
    end

    it "anti-BOLA: notifica altrui → 404" do
      sign_in(account)
      other = create(:account)
      create(:membership, account: other, organization: organization, role: :member)
      foreign = create(:alerting_notification, organization: organization, account: other, via: :in_app)
      patch read_member_alerting_notification_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-323: la riga raggruppata marca letti TUTTI i suoi id (params[:ids]), non solo il rappresentante.
    it "segna come letto l'intero gruppo raggruppato (nessun pallino non letto residuo)" do
      sign_in(account)
      representative = own_notification(read_at: nil)
      sibling = own_notification(read_at: nil)
      patch read_member_alerting_notification_path(representative, ids: [ sibling.id ])
      expect(representative.reload).to be_read
      expect(sibling.reload).to be_read
    end

    it "anti-BOLA: id estranei in params[:ids] vengono ignorati, non segnati letti" do
      sign_in(account)
      representative = own_notification(read_at: nil)
      other = create(:account)
      create(:membership, account: other, organization: organization, role: :member)
      foreign = create(:alerting_notification, organization: organization, account: other, via: :in_app,
                       read_at: nil)
      patch read_member_alerting_notification_path(representative, ids: [ foreign.id ])
      expect(foreign.reload).not_to be_read
    end
  end

  describe "PATCH read_all" do
    it "segna tutte le proprie come lette" do
      sign_in(account)
      own_notification(read_at: nil)
      own_notification(read_at: nil)
      patch read_all_member_alerting_notifications_path
      expect(::Alerting::Notification.where(account: account).unread).to be_empty
      expect(response).to redirect_to(member_alerting_notifications_path)
    end
  end

  describe "DELETE destroy" do
    it "elimina la propria notifica" do
      sign_in(account)
      notification = own_notification
      expect { delete member_alerting_notification_path(notification) }.to change(::Alerting::Notification, :count).by(-1)
    end
  end
end
