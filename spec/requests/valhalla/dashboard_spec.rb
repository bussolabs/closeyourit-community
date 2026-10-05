# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::Dashboard", type: :request do
  # CYRA-170: in Valhalla il god DEVE avere il 2FA. Glielo attivo al volo e completo il secondo fattore,
  # così il login del god arriva a Valhalla; il non-god resta invariato (nessun 2FA, redirect come prima).
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  describe "GET /valhalla" do
    it "god autenticato → 200" do
      sign_in_as(create(:account, god: true))
      get valhalla_root_path
      expect(response).to have_http_status(:ok)
    end

    it "account non-god → redirect alla home" do
      sign_in_as(create(:account, god: false))
      get valhalla_root_path
      expect(response).to redirect_to(root_path)
    end

    it "non autenticato → redirect al login" do
      get valhalla_root_path
      expect(response).to redirect_to(login_path)
    end

    it "rende la pagina nella lingua del god (Localizable → locale account)" do
      sign_in_as(create(:account, god: true, locale: "it"))
      get valhalla_root_path
      expect(response.body).to include('lang="it"')
    end

    it "default inglese quando il god non ha preferenza lingua" do
      sign_in_as(create(:account, god: true, locale: nil))
      get valhalla_root_path
      expect(response.body).to include('lang="en"')
    end

    it "i numeri statistici sono in mono (Mono-For-Data), non font-display" do
      sign_in_as(create(:account, god: true))
      get valhalla_root_path
      doc = Nokogiri::HTML(response.body)
      %w[stat-accounts stat-organizations stat-tickets stat-god].each do |test_id|
        stat = doc.at_css(%([data-test="#{test_id}"]))
        expect(stat["class"]).to include("font-mono")
        expect(stat["class"]).not_to include("font-display")
      end
    end
  end

  describe "segnali operativi (CYRA-36)" do
    before { sign_in_as(create(:account, god: true)) }

    # Accesso god-only ai segnali: la pagina che li contiene è gated dai test in cima
    # ("account non-god → redirect", "non autenticato → redirect al login").

    describe "stato organizzazioni" do
      # DB test condiviso tra worktree: azzero la tabella per conteggi org deterministici.
      before { Organizations::Organization.delete_all }

      it "mostra org attive, sospese e senza owner con i conteggi corretti" do
        active_with_owner = create(:organization)
        create(:membership, organization: active_with_owner, role: :owner)
        create(:organization)                              # attiva, senza owner
        create(:organization, suspended_at: Time.current)  # sospesa, senza owner

        get valhalla_root_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('[data-test="stat-orgs-active"]').text.strip).to start_with("2")
        expect(doc.at_css('[data-test="stat-orgs-suspended"]').text.strip).to start_with("1")
        expect(doc.at_css('[data-test="stat-orgs-without-owner"]').text.strip).to start_with("2")
      end

      it "un'org con owner non è contata tra quelle senza owner" do
        with_owner = create(:organization)
        create(:membership, organization: with_owner, role: :owner)

        get valhalla_root_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('[data-test="stat-orgs-without-owner"]').text.strip).to start_with("0")
      end
    end

    describe "accessi recenti (sessioni come proxy dei login)" do
      it "mostra le sessioni recenti con l'account collegato" do
        tracked = create(:account, email: "seen-login@example.com", name: "Login Watcher")
        create(:session, account: tracked, created_at: 1.minute.ago)

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-recent-sessions"]')
        expect(section).to be_present
        expect(section.text).to include("seen-login@example.com")
      end

      it "non elenca le sessioni scadute o inattive, che il prossimo accesso chiuderebbe" do
        create(:session, :expired, account: create(:account, email: "expired-login@example.com"))
        create(:session, :idle, account: create(:account, email: "idle-login@example.com"))

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-recent-sessions"]')
        expect(section.text).not_to include("expired-login@example.com")
        expect(section.text).not_to include("idle-login@example.com")
      end
    end

    describe "impersonation recenti" do
      it "mostra gli eventi di impersonation god recenti con god e target" do
        god = create(:account, god: true, email: "the-god@example.com")
        target = create(:account, email: "impersonated@example.com")
        create(:impersonation_event, god: god, account: target, started_at: 2.minutes.ago)

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-impersonations"]')
        expect(section).to be_present
        expect(section.text).to include("impersonated@example.com")
        expect(section.text).to include("the-god@example.com")
      end

      it "mostra lo stato vuoto senza impersonation" do
        Accounts::ImpersonationEvent.delete_all

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-impersonations"]')
        expect(section).to be_present
        expect(section.text).to include(I18n.t("valhalla.dashboard.empty_impersonations"))
      end

      # "In corso" deve derivare dalla sessione viva (fonte di verità), non da ended_at: il logout
      # distrugge la sessione ma non chiude l'evento, che resterebbe con ended_at nullo per sempre.
      it "segna 'in corso' solo se esiste una sessione god→target attiva" do
        god = create(:account, god: true)
        target = create(:account, email: "live-target@example.com")
        create(:impersonation_event, god: god, account: target, started_at: 1.minute.ago)
        create(:session, account: god, impersonated_account: target)

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-impersonations"]')
        expect(section.text).to include(I18n.t("valhalla.dashboard.impersonation_active"))
      end

      it "non segna 'in corso' un'impersonation con ended_at nullo ma senza sessione attiva (post-logout)" do
        god = create(:account, god: true)
        target = create(:account, email: "stale-target@example.com")
        # ended_at nullo ma nessuna sessione god→target: il god ha fatto logout (sessione distrutta,
        # evento mai chiuso). Non è più in corso.
        create(:impersonation_event, god: god, account: target, started_at: 3.minutes.ago, ended_at: nil)

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-impersonations"]')
        expect(section.text).to include("stale-target@example.com")
        expect(section.text).not_to include(I18n.t("valhalla.dashboard.impersonation_active"))
      end
    end

    describe "impersonation con sessione scaduta" do
      it "non segna 'in corso' se la sessione god→target è scaduta" do
        god = create(:account, god: true)
        target = create(:account, email: "expired-target@example.com")
        create(:impersonation_event, god: god, account: target, started_at: 20.days.ago)
        create(:session, :expired, account: god, impersonated_account: target)

        get valhalla_root_path

        section = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-impersonations"]')
        expect(section.text).to include("expired-target@example.com")
        expect(section.text).not_to include(I18n.t("valhalla.dashboard.impersonation_active"))
      end
    end

    describe "crescita a 7 giorni" do
      it "mostra i conteggi a 7 giorni coerenti col modello per account/org/ticket" do
        create(:organization, created_at: 2.days.ago)
        create(:organization, created_at: 20.days.ago) # fuori finestra
        create_list(:account, 2, created_at: 3.days.ago)
        create(:ticket, created_at: 1.day.ago)

        get valhalla_root_path

        doc = Nokogiri::HTML(response.body)
        window = (7.days.ago..)
        expect(doc.at_css('[data-test="stat-growth-accounts"]').text.strip)
          .to eq(Accounts::Account.where(created_at: window).count.to_s)
        expect(doc.at_css('[data-test="stat-growth-organizations"]').text.strip)
          .to eq(Organizations::Organization.where(created_at: window).count.to_s)
        expect(doc.at_css('[data-test="stat-growth-tickets"]').text.strip)
          .to eq(Ticketing::Ticket.where(created_at: window).count.to_s)
      end

      it "include gli account al confine dei 7 giorni ed esclude quelli oltre" do
        freeze_time do
          boundary = 7.days.ago
          before_count = Accounts::Account.where(created_at: boundary..).count
          create(:account, created_at: boundary)            # esattamente al confine → incluso (>=)
          create(:account, created_at: boundary - 1.second) # 1s oltre → escluso

          get valhalla_root_path

          cell = Nokogiri::HTML(response.body).at_css('[data-test="stat-growth-accounts"]')
          expect(cell.text.strip.to_i).to eq(before_count + 1)
        end
      end

      it "i conteggi di crescita sono in mono (Mono-For-Data), non font-display" do
        get valhalla_root_path
        doc = Nokogiri::HTML(response.body)
        %w[stat-growth-accounts stat-growth-organizations stat-growth-tickets].each do |test_id|
          stat = doc.at_css(%([data-test="#{test_id}"]))
          expect(stat["class"]).to include("font-mono")
          expect(stat["class"]).not_to include("font-display")
        end
      end
    end
  end

  describe "salute ricerca semantica (CYRA-206)" do
    # Card god-only: il gating è coperto dai test in cima. Conteggi assoluti → azzero i ticket
    # (transazionale, le FK figlie cascano) così il numero mostrato dipende solo da ciò che creo qui.
    before do
      sign_in_as(create(:account, god: true))
      Ticketing::Ticket.delete_all
    end

    it "mostra quante righe sono invisibili alla ricerca e le evidenzia in rosso" do
      visible = create(:ticket)
      visible.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
      hidden = create(:ticket)
      hidden.update_columns(embedding: basis_vector(1), embedding_version: nil)

      get valhalla_root_path

      cell = Nokogiri::HTML(response.body).at_css('[data-test="stat-drift-tickets"]')
      expect(cell.text.strip).to eq("1")
      expect(cell["class"]).to include("text-red-600")
      expect(cell["class"]).to include("font-mono")
    end

    it "nessuna riga invisibile → zero, senza evidenza rossa" do
      ok = create(:ticket)
      ok.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)

      get valhalla_root_path

      cell = Nokogiri::HTML(response.body).at_css('[data-test="stat-drift-tickets"]')
      expect(cell.text.strip).to eq("0")
      expect(cell["class"]).not_to include("text-red-600")
    end

    # CYRA-232: accanto ai "non aggiornati" (versione vecchia) il pannello mostra i "non indicizzati"
    # (mai embeddati). Solo oltre la grazia d'età, così l'attesa normale post-creazione non è un allarme.
    it "mostra i contenuti mai indicizzati oltre la grazia e li evidenzia in rosso" do
      buried = create(:ticket)
      buried.update_columns(embedding: nil, created_at: 2.hours.ago)

      get valhalla_root_path

      cell = Nokogiri::HTML(response.body).at_css('[data-test="stat-missing-tickets"]')
      expect(cell.text.strip).to eq("1")
      expect(cell["class"]).to include("text-red-600")
      expect(cell["class"]).to include("font-mono")
    end

    it "la normale attesa post-creazione non conta tra i mai indicizzati (niente rosso)" do
      fresh = create(:ticket)
      fresh.update_columns(embedding: nil, created_at: 1.minute.ago)

      get valhalla_root_path

      cell = Nokogiri::HTML(response.body).at_css('[data-test="stat-missing-tickets"]')
      expect(cell.text.strip).to eq("0")
      expect(cell["class"]).not_to include("text-red-600")
    end
  end

  # What needs the god comes first, one row per problem, each with the page that fixes it.
  describe "needs attention" do
    before do
      sign_in_as(create(:account, god: true))
      Ticketing::Ticket.delete_all
      Organizations::Organization.delete_all
    end

    def attention = Nokogiri::HTML(response.body).at_css('[data-test="valhalla-dashboard-attention"]')

    it "says all good when nothing is wrong" do
      get valhalla_root_path

      expect(attention.text).to include(I18n.t("valhalla.dashboard.attention_empty"))
      expect(attention.css("tbody tr")).to be_empty
    end

    it "lists content missing from the search index, with the way to AI settings" do
      create(:ticket).update_columns(embedding: nil, created_at: 2.hours.ago)

      get valhalla_root_path

      row = attention.at_css('[data-test="valhalla-attention-drift-tickets"]')
      expect(row.text).to include(I18n.t("valhalla.dashboard.attention.drift_tickets", count: 1))
      expect(row.at_css("a")["href"]).to eq(valhalla_ai_settings_path)
    end

    it "lists suspended organizations and the ones without an owner" do
      create(:organization, suspended_at: Time.current)

      get valhalla_root_path

      expect(attention.at_css('[data-test="valhalla-attention-suspended"]').text)
        .to include(I18n.t("valhalla.dashboard.attention.suspended", count: 1))
      expect(attention.at_css('[data-test="valhalla-attention-without-owner"] a')["href"]).to eq(valhalla_organizations_path)
    end
  end

  describe "recent organizations — paginazione" do
    before { sign_in_as(create(:account, god: true)) }

    it "rende il footer di paginazione" do
      create(:organization)
      get valhalla_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="valhalla-dashboard-recent-pagination"')
    end

    context "con più di una pagina di org recenti (> TABLE_PER_PAGE)" do
      # TABLE_PER_PAGE + 1 org → 2 pagine. Ordine created_at DESC: le più recenti in pagina 1,
      # la più vecchia (unica) in pagina 2. Pulisco la tabella (DB test condiviso tra worktree).
      before { Organizations::Organization.delete_all }

      let!(:organizations) do
        (App::Constants::TABLE_PER_PAGE + 1).times.map do |i|
          create(:organization, slug: "rec-org-#{format('%02d', i)}", created_at: (i + 1).minutes.ago)
        end
      end

      let(:oldest) { organizations.last } # created_at più vecchio → unica org di pagina 2

      it "pagina 2 risponde 200 e mostra org diverse dalla pagina 1" do
        get valhalla_root_path, params: { page: 1 }
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(oldest.slug)

        get valhalla_root_path, params: { page: 2 }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(oldest.slug)
      end
    end
  end

  # CYRA-924 — the three dashboard tables sort on their columns (C9), each on its own param.
  describe "sort" do
    before { sign_in_as(create(:account, god: true)) }

    it "sorts the recent organizations by name both ways and offers every column" do
      create(:organization, name: "Zeta Labs")
      create(:organization, name: "alpha Works")
      names = -> { Nokogiri::HTML(response.body).css("[data-test='valhalla-dashboard-recent'] tbody tr").map(&:text).join }

      get valhalla_root_path(organizations_sort: "organization")
      expect(names.call.index("alpha Works")).to be < names.call.index("Zeta Labs")
      get valhalla_root_path(organizations_sort: "-organization")
      expect(names.call.index("Zeta Labs")).to be < names.call.index("alpha Works")
      %w[organization slug owner created].each { |key| expect(response.body).to include("organizations_sort=#{key}").or include("organizations_sort=-#{key}") }
      %w[account ip when].each { |key| expect(response.body).to include("sessions_sort=#{key}").or include("sessions_sort=-#{key}") }
    end

    it "sorts the recent organizations by owner, not by any member" do
      zeta = create(:organization, name: "Owned by zed")
      alpha = create(:organization, name: "Owned by amy")
      create(:membership, organization: zeta, role: :owner, account: create(:account, email: "zed@x.test"))
      create(:membership, organization: zeta, role: :member, account: create(:account, email: "aaa@x.test"))
      create(:membership, organization: alpha, role: :owner, account: create(:account, email: "amy@x.test"))
      names = -> { Nokogiri::HTML(response.body).css("[data-test='valhalla-dashboard-recent'] tbody tr").map(&:text).join }

      get valhalla_root_path(organizations_sort: "owner")
      expect(names.call.index("Owned by amy")).to be < names.call.index("Owned by zed")
    end
  end
end
