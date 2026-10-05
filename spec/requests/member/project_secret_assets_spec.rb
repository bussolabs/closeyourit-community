# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectSecretAssets", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in_as(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def sign_in
    sign_in_as(owner)
  end

  it "rende la pagina per un owner e nega un membro senza permesso" do
    sign_in
    get member_project_secret_assets_path(project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"member-project-secret-assets\"")
  end

  it "shares the secrets header: tabs, subtitle and no Vault button" do
    sign_in
    get member_project_secret_assets_path(project)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("[data-test='secrets-subnav-files'][aria-current='page']")).to be_present
    expect(document.at_css("[data-test='project-secret-assets-lead']")).to be_present
    expect(document.at_css("[data-test='project-secret-assets-env-link']")).to be_nil
    expect(document.css("[data-test='member-project-secret-assets'] h2").map(&:text)).not_to include(I18n.t("member.secret_assets.section_title"))
  end

  it "keeps Archive in the more menu of each file" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last
    get member_project_secret_assets_path(project)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("details:has([data-test='project-secret-asset-menu-#{asset.id}']) [data-test='project-secret-asset-archive-#{asset.id}']")).to be_present
    expect(document.at_css("[data-test='project-secret-asset-versions-#{asset.id}']")).to be_present
  end

  it "shows the file versions under the project header and tabs" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    get versions_member_project_secret_asset_path(project, project.secret_assets.last)
    expect(response.body).to include('data-test="secrets-subnav"')
  end

  it "isola i progetti di un'altra organizzazione" do
    sign_in
    get member_project_secret_assets_path(create(:project))
    expect(response).to have_http_status(:not_found)
  end

  it "rende il caricamento su una pagina dedicata" do
    sign_in
    get new_member_project_secret_asset_path(project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"project-secret-asset-form\"")
  end

  it "carica un file segreto e reindirizza all'elenco" do
    sign_in
    expect do
      post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    end.to change { project.secret_assets.count }.by(1)
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(member_project_secret_assets_path(project))
  end

  it "scarica il file restituendo il contenuto esatto e non svuotato (CYRA-134)" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last

    get download_member_project_secret_asset_path(project, asset)

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    expect(response.headers["Content-Disposition"]).to include("attachment")
  end

  it "scarica la versione indicata invece di quella corrente" do
    sign_in
    post member_project_secret_assets_path(project),
         params: { confirm: "1", name: "APNs key", file: p8_upload(body: "-----BEGIN " + "PRIVATE KEY-----\nversione-1\n-----END PRIVATE KEY-----") }
    asset = project.secret_assets.last
    # seconda versione (corrente) con contenuto diverso, così il download by-version è distinguibile
    ::Secrets::Assets::Upload.call(asset:, actor: owner,
                                   uploaded_file: p8_upload(body: "-----BEGIN " + "PRIVATE KEY-----\nversione-2\n-----END PRIVATE KEY-----"))
    expect(asset.reload.versions.count).to eq(2)

    get download_member_project_secret_asset_path(project, asset), params: { version: 1 }

    expect(response).to have_http_status(:ok)
    # deve restituire il contenuto della v1, non quello della versione corrente (v2)
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\nversione-1\n-----END PRIVATE KEY-----")
  end

  it "associa l'asset a un environment del progetto quando indicato" do
    sign_in
    environment = create(:environment, organization:)
    create(:project_environment, project:, environment:)

    post member_project_secret_assets_path(project), params: { confirm: "1", name: "Scoped", environment_id: environment.id, file: p8_upload }

    expect(response).to have_http_status(:see_other)
    expect(project.secret_assets.last.environment_id).to eq(environment.id)
  end

  it "ripropone la pagina di caricamento quando l'upload non è valido" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "Invalid", file: invalid_p8_upload }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("data-test=\"project-secret-asset-form\"")
  end

  it "elenca le versioni di un asset per chi può leggere" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last

    get versions_member_project_secret_asset_path(project, asset)

    expect(response).to have_http_status(:ok)
  end

  it "archivia un asset e reindirizza all'elenco" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last

    delete member_project_secret_asset_path(project, asset), params: { confirm: "1" }

    expect(response).to redirect_to(member_project_secret_assets_path(project))
    expect(asset.reload.archived_at).to be_present
  end

  it "elimina definitivamente un asset già archiviato" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last
    asset.update!(archived_at: Time.current)

    expect do
      delete purge_member_project_secret_asset_path(project, asset), params: { confirm: "1" }
    end.to change { Secrets::Asset.where(id: asset.id).count }.from(1).to(0)
    expect(response).to redirect_to(member_project_secret_assets_path(project))
  end

  it "rifiuta il purge di un asset non ancora archiviato" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last

    delete purge_member_project_secret_asset_path(project, asset), params: { confirm: "1" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(Secrets::Asset.where(id: asset.id)).to exist
  end

  # Scenario 2 del ticket: dopo un rollback il file temporaneo decifrato non deve restare leggibile sul disco.
  it "ripristina una versione precedente senza lasciare copie temporanee sul disco" do
    sign_in
    post member_project_secret_assets_path(project), params: { confirm: "1", name: "APNs key", file: p8_upload }
    asset = project.secret_assets.last

    temps = []
    allow(Tempfile).to receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
      created = original.call(*args, **kwargs, &block)
      temps << created if args.first == "secret-asset"
      created
    end

    expect do
      post rollback_member_project_secret_asset_path(project, asset), params: { confirm: "1", version: 1 }
    end.to change { asset.versions.count }.by(1)

    expect(response).to redirect_to(versions_member_project_secret_asset_path(project, asset))
    expect(temps).not_to be_empty
    expect(temps).to all(be_closed)          # il blocco ensure ha chiuso il tempfile
    expect(temps.map(&:path)).to all(be_nil) # close! l'ha rimosso dal disco: nessun residuo leggibile
  end

  # Scenario 1 del ticket: chi ha solo l'accesso base al progetto viene respinto su ogni azione sui file segreti.
  context "un membro con accesso al progetto ma senza permessi sui file segreti" do
    let(:restricted) { create(:account) }

    before do
      create(:membership, account: restricted, organization:, role: :member)
      create(:project_membership, account: restricted, project:)
    end

    it "viene respinto su lettura, versioni, caricamento, rollback, archiviazione ed eliminazione" do
      sign_in_as(restricted)
      missing = SecureRandom.uuid

      get member_project_secret_assets_path(project)
      expect(response).to redirect_to(root_path)

      get download_member_project_secret_asset_path(project, missing)
      expect(response).to redirect_to(root_path)

      get versions_member_project_secret_asset_path(project, missing)
      expect(response).to redirect_to(root_path)

      get new_member_project_secret_asset_path(project)
      expect(response).to redirect_to(root_path)

      post member_project_secret_assets_path(project), params: { name: "X", file: p8_upload }
      expect(response).to redirect_to(root_path)

      post rollback_member_project_secret_asset_path(project, missing), params: { version: 1 }
      expect(response).to redirect_to(root_path)

      delete member_project_secret_asset_path(project, missing)
      expect(response).to redirect_to(root_path)

      delete purge_member_project_secret_asset_path(project, missing)
      expect(response).to redirect_to(root_path)
    end
  end

  def p8_upload(body: "-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    file = Tempfile.new([ "AuthKey_TEST", ".p8" ])
    file.write(body)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "AuthKey_TEST.p8")
  end

  def invalid_p8_upload
    file = Tempfile.new([ "invalid", ".p8" ])
    file.write("not a private key")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "invalid.p8")
  end

  # CYRA-422 — la spiegazione della protezione dei file segreti è nel corpo (non in un tooltip), più la
  # riga permanente su cifratura, tracciamento e retention.
  describe "GET index — protezione nel corpo (CYRA-422)" do
    it "porta la descrizione della protezione nel corpo e aggiunge la riga permanente" do
      sign_in
      get member_project_secret_assets_path(project)

      expect(response.body).to include('data-test="project-secret-assets-lead"')
      expect(response.body).to include(I18n.t("member.secret_assets.section_lead"))
      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).not_to include('data-test="project-secret-assets-help"')
    end
  end

  # CYRA-666 — il confine ambienti (CYRA-78/CYRA-268) vale anche sul canale web. Il gemello CLI lo
  # applica gia' (cli/v1/projects/secret_assets_controller.rb:128-135); qui mancava del tutto, quindi
  # un account confinato a staging scaricava dal browser la chiave di produzione. Come sul canale CLI,
  # per i file NON si scrive un evento "denied": l'audit dei file ha il suo vocabolario.
  describe "confine ambienti per-utente (CYRA-666)" do
    let(:member) { create(:account) }
    let(:production) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
    let(:staging) { create(:environment, organization:, code: "staging").tap { |e| project.environments << e } }

    def asset_in(environment, name:)
      asset = project.secret_assets.new(name:, environment:, organization:, asset_type: "p8", created_by: owner)
      ::Secrets::Assets::Upload.call(asset:, actor: owner, uploaded_file: p8_upload)
      asset.reload
    end

    before do
      production
      staging
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      create(:account_permission, account: member, organization:, permission_key: "secret_files.read", effect: :allow)
      organization.memberships.find_by!(account: member).update!(secret_environment_codes: [ "staging" ])
    end

    describe "GET download" do
      it "file di un ambiente vietato -> rimbalzo, nessun contenuto servito" do
        asset = asset_in(production, name: "AuthKey_PROD")
        sign_in_as(member)

        get download_member_project_secret_asset_path(project, asset)

        expect(response).not_to have_http_status(:ok)
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
      end

      # CYRA-666 — il tentativo bloccato deve restare nel registro: provare a scaricare una chiave
      # privata di produzione e' esattamente l'evento che si vuole ritrovare.
      it "il tentativo lascia un evento denied con file, ambiente, attore e canale" do
        asset = asset_in(production, name: "AuthKey_PROD")
        sign_in_as(member)

        expect do
          get download_member_project_secret_asset_path(project, asset)
        end.to change { Secrets::AssetEvent.where(action: "denied").count }.by(1)

        event = Secrets::AssetEvent.where(action: "denied").last
        expect(event.asset).to eq(asset)
        expect(event.environment).to eq(production)
        expect(event.actor).to eq(member)
        expect(event.project).to eq(project)
        expect(event.metadata["channel"]).to eq("web")
      end

      it "file di un ambiente consentito -> il download funziona" do
        asset = asset_in(staging, name: "AuthKey_STAGING")
        sign_in_as(member)

        get download_member_project_secret_asset_path(project, asset)

        expect(response).to have_http_status(:ok)
      end
    end

    describe "GET versions" do
      it "storico di un file vietato -> rimbalzo" do
        asset = asset_in(production, name: "AuthKey_PROD")
        sign_in_as(member)

        get versions_member_project_secret_asset_path(project, asset)

        expect(response).not_to have_http_status(:ok)
      end
    end

    describe "GET index" do
      it "non elenca i file degli ambienti vietati" do
        asset_in(production, name: "AuthKey_PROD")
        asset_in(staging, name: "AuthKey_STAGING")
        sign_in_as(member)

        get member_project_secret_assets_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AuthKey_STAGING")
        expect(response.body).not_to include("AuthKey_PROD")
      end
    end

    describe "mutazioni" do
      before { create(:account_permission, account: member, organization:, permission_key: "secret_files.manage", effect: :allow) }

      it "archiviare un file di un ambiente vietato -> rimbalzo e file intatto" do
        asset = asset_in(production, name: "AuthKey_PROD")
        sign_in_as(member)

        delete member_project_secret_asset_path(project, asset)

        expect(asset.reload.archived_at).to be_nil
      end

      it "caricare su un ambiente vietato -> niente file nuovo" do
        sign_in_as(member)

        expect do
          post member_project_secret_assets_path(project),
               params: { name: "AuthKey_NEW", environment_id: production.id, file: p8_upload }
        end.not_to change { project.secret_assets.count }
      end

      # Il rifiuto sul caricamento avviene PRIMA che il file esista: l'evento non ha un asset, e senza
      # progetto/ambiente/nome tentato sarebbe orfano, cioe' inutile a chi indaga.
      it "il caricamento rifiutato lascia un evento denied senza file ma col contesto" do
        sign_in_as(member)

        expect do
          post member_project_secret_assets_path(project),
               params: { confirm: "1", name: "AuthKey_NEW", environment_id: production.id, file: p8_upload }
        end.to change { Secrets::AssetEvent.where(action: "denied").count }.by(1)

        event = Secrets::AssetEvent.where(action: "denied").last
        expect(event.asset).to be_nil
        expect(event.environment).to eq(production)
        expect(event.project).to eq(project)
        expect(event.actor).to eq(member)
        expect(event.metadata["name"]).to eq("AuthKey_NEW")
        expect(event.metadata["channel"]).to eq("web")
      end
    end
  end
end
