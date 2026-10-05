# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Platforms", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: admin, organization: org, role: :admin)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_platforms_path
      expect(response).to redirect_to(login_path)
    end

    # E11 — "Uptime: yes/no" is not the state of a service: the header says what the column means.
    it "explains the Uptime column on its header" do
      sign_in(owner)
      create(:platform, organization: org)
      get member_platforms_path

      expect(response.body).to include('data-test="platforms-col-uptime-hint"')
    end

    it "membro semplice senza permesso → redirect a root (gate platforms.view)" do
      sign_in(member)
      create(:platform, organization: org)
      get member_platforms_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con platforms.view → 200" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "platforms.view" ], actor: owner
      )
      sign_in(member)
      create(:platform, organization: org)
      get member_platforms_path
      expect(response).to have_http_status(:ok)
    end

    it "pagina: pagina 1 piena (TABLE_PER_PAGE righe) + footer, resto in pagina 2" do
      sign_in(owner)
      create_list(:platform, App::Constants::TABLE_PER_PAGE + 1, organization: org)

      get member_platforms_path, params: { page: 1 }
      expect(response.body.scan('data-test="member-platform"').size).to eq(App::Constants::TABLE_PER_PAGE)
      expect(response.body).to include('data-test="platforms-pagination"')

      get member_platforms_path, params: { page: 2 }
      expect(response.body.scan('data-test="member-platform"').size).to eq(1)
    end
  end

  describe "GET new" do
    it "admin → 200" do
      sign_in(owner)
      get new_member_platform_path
      expect(response).to have_http_status(:ok)
    end

    it "membro semplice → redirect (forbidden)" do
      sign_in(member)
      get new_member_platform_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "admin crea (code normalizzato, created_by)" do
      sign_in(owner)
      expect do
        post member_platforms_path, params: { label: "iOS", code: "iOS", color: "sky", active: "1" }
      end.to change(Types::Platform, :count).by(1)
      platform = Types::Platform.last
      expect(platform.code).to eq("ios")
      expect(platform.created_by).to eq(owner)
      expect(response).to redirect_to(member_platforms_path)
    end

    it "membro semplice → redirect, niente creato" do
      sign_in(member)
      expect do
        post member_platforms_path, params: { label: "X", code: "x" }
      end.not_to change(Types::Platform, :count)
      expect(response).to redirect_to(root_path)
    end

    it "dati invalidi → 422" do
      sign_in(owner)
      post member_platforms_path, params: { label: "", code: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET edit / PATCH update" do
    it "admin → 200 (render form)" do
      sign_in(owner)
      platform = create(:platform, organization: org)
      get edit_member_platform_path(platform)
      expect(response).to have_http_status(:ok)
    end

    it "admin aggiorna" do
      sign_in(owner)
      platform = create(:platform, organization: org, label: "Old")
      patch member_platform_path(platform),
            params: { label: "New", code: platform.code, color: platform.color, active: "1" }
      expect(platform.reload.label).to eq("New")
      expect(response).to redirect_to(member_platforms_path)
    end

    it "update invalido (code vuoto) → ri-renderizza il form 422" do
      sign_in(owner)
      platform = create(:platform, organization: org, label: "Old")
      patch member_platform_path(platform), params: { code: "", label: "New" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(platform.reload.label).to eq("Old")
    end

    it "edit di una platform di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:platform, organization: create(:organization))
      get edit_member_platform_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "admin elimina una platform inutilizzata" do
      sign_in(owner)
      platform = create(:platform, organization: org)
      expect do
        delete member_platform_path(platform)
      end.to change(Types::Platform, :count).by(-1)
      expect(response).to redirect_to(member_platforms_path)
    end

    it "platform in uso → non eliminata (restrict), alert" do
      sign_in(owner)
      platform = create(:platform, organization: org)
      create(:project, organization: org).platforms << platform
      expect do
        delete member_platform_path(platform)
      end.not_to change(Types::Platform, :count)
      expect(response).to redirect_to(member_platforms_path)
    end
  end

  describe "GET index — filtri" do
    before { sign_in(owner) }

    it "filtra per stato attivo" do
      create(:platform, organization: org, label: "ActiveOne", active: true)
      create(:platform, organization: org, label: "InactiveOne", active: false)
      get member_platforms_path, params: { status: [ "true" ] }
      expect(response.body).to include("ActiveOne")
      expect(response.body).not_to include("InactiveOne")
    end

    it "filtra per stato inattivo" do
      create(:platform, organization: org, label: "ActiveOne", active: true)
      create(:platform, organization: org, label: "InactiveOne", active: false)
      get member_platforms_path, params: { status: [ "false" ] }
      expect(response.body).to include("InactiveOne")
      expect(response.body).not_to include("ActiveOne")
    end

    it "search per label/code" do
      create(:platform, organization: org, label: "Searchable", code: "srch")
      create(:platform, organization: org, label: "HiddenLabel", code: "hide")
      get member_platforms_path, params: { q: "Searchable" }
      expect(response.body).to include("Searchable")
      expect(response.body).not_to include("HiddenLabel")
    end

    it "search senza match → box no-match (filtro azzerabile)" do
      create(:platform, organization: org, label: "Whatever")
      get member_platforms_path, params: { q: "zzzznomatch" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("platforms-no-match")
    end

    it "param array con blank ignorati (filter_ids)" do
      create(:platform, organization: org, label: "KeepMe", active: true)
      get member_platforms_path, params: { status: [ "" ] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("KeepMe")
    end
  end

  # CYRA-441 — la pagina apriva su una tabella senza una parola su cosa fosse una piattaforma: chi
  # arrivava la prima volta doveva indovinare. Due righe in cima dicono cos'è e dove viene usata, e
  # il rimando porta alla guida dei contenitori.
  describe "l'intro in cima alla pagina" do
    def intro
      Nokogiri::HTML(response.body).at_css('[data-test="platforms-intro"]')
    end

    it "dice cos'è una piattaforma e dove viene usata" do
      sign_in(owner)
      create(:platform, organization: org)

      get member_platforms_path

      expect(intro).to be_present
      expect(intro.text).to include(I18n.t("member.platforms.intro.what"))
      expect(intro.text).to include(I18n.t("member.platforms.intro.where"))
    end

    it "c'è anche quando non ce n'è ancora nessuna: è lì che serve di più" do
      sign_in(owner)

      get member_platforms_path

      expect(response.body).to include('data-test="platforms-empty"')
      expect(intro).to be_present
    end

    it "rimanda alla guida che spiega i contenitori" do
      sign_in(owner)

      get member_platforms_path

      expect(intro.at_css('[data-test="platforms-intro-guide"]')["href"]).to eq(member_guides_structure_path)
    end

    it "floats over the content instead of sitting loose above the table, and stays closed once closed" do
      sign_in(owner)

      get member_platforms_path
      expect(response.body).to match(/<aside[^>]+data-test="platforms-intro"/)
      expect(intro.text).to include(I18n.t("member.platforms.intro.title"))

      owner.update!(dismissed_notices: [ "platforms_intro" ])
      get member_platforms_path
      expect(intro).to be_nil
    end
  end

  describe "capability supports_uptime" do
    it "crea una piattaforma uptime-capable quando il flag è spuntato" do
      sign_in(owner)
      post member_platforms_path, params: { label: "Web", code: "web", color: "violet", active: "1", supports_uptime: "1" }
      expect(Types::Platform.find_by(code: "web").supports_uptime).to be(true)
    end

    it "default false quando il flag non è inviato (hidden 0)" do
      sign_in(owner)
      post member_platforms_path, params: { label: "iOS", code: "ios", color: "sky", active: "1", supports_uptime: "0" }
      expect(Types::Platform.find_by(code: "ios").supports_uptime).to be(false)
    end

    it "aggiorna la capability di una piattaforma esistente" do
      sign_in(owner)
      platform = create(:platform, organization: org, supports_uptime: false)
      patch member_platform_path(platform),
            params: { label: platform.label, code: platform.code, color: platform.color, active: "1", supports_uptime: "1" }
      expect(platform.reload.supports_uptime).to be(true)
    end
  end

  # CYRA-924 — delete asks in a dialog that names the platform, never in the browser box (F16, C77).
  describe "delete confirmation" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      platform = create(:platform, organization: org, label: "iOS")

      get member_platforms_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='platform-delete-dialog-#{platform.id}']")
      expect(dialog.text).to include(I18n.t("member.platforms.delete_dialog.title", label: "iOS"))
      expect(dialog.at_css("form")["action"]).to eq(member_platform_path(platform))
      expect(html.at_css("[data-test='platform-delete-#{platform.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
