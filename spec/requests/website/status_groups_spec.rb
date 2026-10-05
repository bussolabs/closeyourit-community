# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Website::StatusGroups", type: :request do
  let(:org) { create(:organization, slug: "acme") }
  let(:project) do
    create(:project, organization: org, key: "MYAP", name: "My App").tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) do
    create(:environment, organization: org, code: "production", label: "Production").tap { |e| project.environments << e }
  end
  let(:group) { create(:uptime_group, organization: org, name: "Servizi Critici") }

  def publish!(the_group = group)
    the_group.update_column(:public_status_enabled, true)
    the_group
  end

  def monitor_in_group(the_group, **attrs)
    create(:uptime_monitor, project: project, environment: environment, group: the_group, **attrs)
  end

  def path_for(slug: org.slug, group_slug: group.slug)
    public_group_status_path(slug, group_slug)
  end

  describe "GET /status/g/:org_slug/:group_slug" do
    it "gruppo pubblicato → 200, senza login, coi servizi del gruppo" do
      publish!
      monitor = monitor_in_group(group, current_status: :up)
      create(:uptime_check, monitor: monitor, up: true, checked_at: 5.minutes.ago)

      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Servizi Critici")
      expect(response.body).to include("My App")
      expect(response.body).to include('data-test="public-group-status"')
      expect(response.body).to include("status-service-#{monitor.id}")
      expect(response.body).to include('<main id="main-content"') # skip-link target (a11y)
    end

    it "gruppo NON pubblicato → 404 (opt-in: spento di default)" do
      monitor_in_group(group)
      get path_for
      expect(response).to have_http_status(:not_found)
    end

    it "org slug inesistente → 404" do
      publish!
      get path_for(slug: "nope")
      expect(response).to have_http_status(:not_found)
    end

    it "group slug inesistente → 404" do
      publish!
      get path_for(group_slug: "zzz")
      expect(response).to have_http_status(:not_found)
    end

    it "gruppo di un'altra org (cross-tenant) → 404" do
      other = create(:uptime_group, organization: create(:organization, slug: "beta"))
      other.update_column(:public_status_enabled, true)
      get public_group_status_path(org.slug, other.slug)
      expect(response).to have_http_status(:not_found)
    end

    it "imposta Cache-Control: no-store" do
      publish!
      monitor_in_group(group)
      get path_for
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "non espone dati interni (l'url del monitor non compare)" do
      publish!
      monitor_in_group(group, url: "https://secret-internal.test/up")
      get path_for
      expect(response.body).not_to include("secret-internal.test")
    end

    it "mostra lo storico incidenti del gruppo con il servizio di riferimento" do
      publish!
      monitor = monitor_in_group(group, current_status: :down)
      create(:uptime_incident, monitor: monitor, started_at: 2.hours.ago, resolved_at: 1.hour.ago)
      get path_for
      expect(response.body).to include('data-test="incident-history"')
      expect(response.body).to include("My App")
    end

    it "lo stato per-servizio non è veicolato dal solo colore: sr-only + mini-timeline aria-hidden" do
      publish!
      monitor = monitor_in_group(group, current_status: :up)
      create(:uptime_check, monitor: monitor, up: true, checked_at: 5.minutes.ago)
      get path_for

      row = Nokogiri::HTML(response.body).at_css("[data-test='status-service-#{monitor.id}']")
      expect(row.at_css("span.sr-only").text).to be_present
      expect(row.at_css(".flex.items-stretch")["aria-hidden"]).to eq("true")
    end

    { "it" => "1 parziale,", "en" => "1 partial," }.each do |locale, expected|
      it "un solo blocco parziale → «#{expected.chomp(',')}» al singolare (#{locale})" do
        publish!
        monitor = monitor_in_group(group, current_status: :up)
        create(:uptime_check, monitor: monitor, up: true, checked_at: 5.minutes.ago)
        create(:uptime_check, monitor: monitor, up: false, checked_at: 4.minutes.ago)

        get path_for, params: { range: "24h", locale: locale }
        text = Nokogiri::HTML(response.body).at_css("[data-test='status-service-#{monitor.id}'] p.sr-only").text
        expect(text).to include(expected)
      end
    end

    it "un servizio fresco up + uno col dato vecchio (worker fermo) → gruppo degraded (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        publish!
        monitor_in_group(group, current_status: :up, last_checked_at: 30.seconds.ago)
        env2 = create(:environment, organization: org).tap { |e| project.environments << e }
        create(:uptime_monitor, project:, environment: env2, group:, current_status: :up, last_checked_at: 1.hour.ago)

        get path_for

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-state="degraded"')
        expect(response.body).not_to include('data-state="operational"')
        expect(response.body).to include("Unknown") # sr-only del servizio stale
      end
    end

    it "tutti i servizi col dato vecchio → gruppo unknown, non operational (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        publish!
        monitor_in_group(group, current_status: :up, last_checked_at: 1.hour.ago)

        get path_for

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-state="unknown"')
        expect(response.body).not_to include('data-state="operational"')
      end
    end

    # CYRA-715 — i due divieti vanno tolti INSIEME: `frame-ancestors 'self'` della policy dice la
    # stessa cosa di X-Frame-Options e i browser moderni le danno la precedenza, quindi toglierne uno
    # solo lascerebbe l'embed rotto con questa prova ancora verde.
    it "è incorporabile in un sito di terzi: nessun divieto di incorniciamento sulla risposta" do
      publish!
      monitor_in_group(group, current_status: :up)
      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.headers).not_to have_key("X-Frame-Options")
      expect(csp_of(response)).not_to include("frame-ancestors")
    end
  end

  describe "GET /status/g/:org_slug/:group_slug/badge" do
    def badge_path_for(slug: org.slug, group_slug: group.slug)
      public_group_status_badge_path(slug, group_slug)
    end

    it "gruppo pubblicato → 200 col badge, lo stato scritto e il link alla pagina completa" do
      publish!
      monitor_in_group(group, current_status: :up)

      get badge_path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="status-badge"')
      expect(response.body).to include('data-state="operational"')
      expect(response.body).to include(I18n.t("website.status_group.headline.operational"))
      expect(response.body).to include(public_group_status_url(org.slug, group.slug))
    end

    it "la rotta del gruppo vince su quella per-monitor: /status/g/... risolve il GRUPPO" do
      publish!
      monitor_in_group(group, current_status: :up)

      # Senza l'ordine di dichiarazione, /status/g/acme/servizi/badge combacerebbe anche con
      # status/:org_slug/:project_key/:environment_code/badge (org "g", key "acme", env "servizi").
      expect(Rails.application.routes.recognize_path("/status/g/#{org.slug}/#{group.slug}/badge"))
        .to include(controller: "website/status_groups", action: "badge")
    end

    it "è incorporabile in un sito di terzi e non viene messo in cache" do
      publish!
      monitor_in_group(group, current_status: :up)
      get badge_path_for
      expect(response.headers).not_to have_key("X-Frame-Options")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "un servizio giù → tutto il gruppo down, mai operational" do
      publish!
      env2 = create(:environment, organization: org, code: "staging", label: "Staging").tap { |e| project.environments << e }
      monitor_in_group(group, current_status: :up)
      create(:uptime_monitor, project:, environment: env2, group:, current_status: :down)

      get badge_path_for
      expect(response.body).to include('data-state="down"')
      expect(response.body).not_to include('data-state="operational"')
    end

    it "un servizio col dato vecchio accanto a uno su → degraded, mai operational (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        publish!
        env2 = create(:environment, organization: org, code: "staging", label: "Staging").tap { |e| project.environments << e }
        monitor_in_group(group, current_status: :up, last_checked_at: 1.minute.ago)
        create(:uptime_monitor, project:, environment: env2, group:, current_status: :up, last_checked_at: 1.hour.ago)

        get badge_path_for
        expect(response.body).to include('data-state="degraded"')
        expect(response.body).not_to include('data-state="operational"')
      end
    end

    it "gruppo NON pubblicato → 404 (stesso gate opt-in della pagina)" do
      monitor_in_group(group, current_status: :up)
      get badge_path_for
      expect(response).to have_http_status(:not_found)
    end

    it "org slug inesistente → 404" do
      publish!
      get badge_path_for(slug: "nope")
      expect(response).to have_http_status(:not_found)
    end

    it "group slug inesistente → 404" do
      publish!
      get badge_path_for(group_slug: "zzz")
      expect(response).to have_http_status(:not_found)
    end
  end
end
