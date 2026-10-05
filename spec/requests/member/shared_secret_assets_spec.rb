# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::SharedSecretAssets", type: :request do
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

  def sign_in(account = owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "rende l'elenco per un owner" do
    sign_in
    get member_shared_secret_assets_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"member-shared-secret-assets\"")
  end

  it "nega l'accesso a un membro senza permesso" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    sign_in(member)
    get member_shared_secret_assets_path
    expect(response).not_to have_http_status(:ok)
  end

  it "rende il caricamento su una pagina dedicata" do
    sign_in
    get new_member_shared_secret_asset_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"shared-secret-asset-form\"")
  end

  it "keeps the upload error in sight when the form is in the member modal (CYRA-933)" do
    sign_in
    post member_shared_secret_assets_path, params: { confirm: "1", name: "Invalid", file: invalid_p8_upload },
                                           headers: { "Turbo-Frame" => "modal" }

    frame = Nokogiri::HTML(response.body).at_css("turbo-frame#modal")
    expect(frame.at_css("[data-test='modal-flash'] [role='alert'], [data-test='modal-flash'] .alert, [data-test='modal-flash'] > *")).to be_present
  end

  it "carica un file segreto condiviso e reindirizza all'elenco" do
    sign_in
    expect do
      post member_shared_secret_assets_path, params: { confirm: "1", name: "APNs shared", file: p8_upload }
    end.to change { organization.secret_assets.where(project_id: nil).count }.by(1)
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(member_shared_secret_assets_path)
  end

  it "ripropone la pagina di caricamento quando l'upload non è valido" do
    sign_in
    post member_shared_secret_assets_path, params: { confirm: "1", name: "Invalid", file: invalid_p8_upload }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("data-test=\"shared-secret-asset-form\"")
  end

  it "delega e revoca un asset condiviso verso un progetto" do
    asset = create_shared_asset
    sign_in
    expect do
      post member_shared_secret_asset_delegations_path(asset), params: { confirm: "1", project_id: project.id }
    end.to change { asset.delegations.count }.by(1)

    delegation = asset.delegations.find_by(project:)
    expect do
      delete member_shared_secret_asset_delegation_path(asset, delegation), params: { confirm: "1" }
    end.to change { asset.delegations.count }.by(-1)
  end

  it "archivia un asset condiviso" do
    asset = create_shared_asset
    sign_in
    delete member_shared_secret_asset_path(asset), params: { confirm: "1" }
    expect(asset.reload.archived_at).to be_present
  end

  it "mostra lo storico versioni di un file segreto condiviso (parita con progetto/personale)" do
    asset = create_shared_asset
    Secrets::Assets::Upload.call(asset:, uploaded_file: p8_upload, actor: owner)
    Secrets::Assets::Upload.call(asset:, uploaded_file: p8_upload, actor: owner)
    sign_in

    get versions_member_shared_secret_asset_path(asset)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"shared-secret-asset-versions\"")
    expect(asset.versions.count).to eq(2)
  end

  it "ripristina una versione precedente creando una nuova versione" do
    asset = create_shared_asset
    Secrets::Assets::Upload.call(asset:, uploaded_file: p8_upload, actor: owner)
    Secrets::Assets::Upload.call(asset:, uploaded_file: p8_upload, actor: owner)
    sign_in

    expect do
      post rollback_member_shared_secret_asset_path(asset), params: { confirm: "1", version: 1 }
    end.to change { asset.versions.count }.by(1)
  end

  it "scarica il file condiviso restituendo il contenuto esatto e non svuotato (CYRA-134)" do
    asset = create_shared_asset
    Secrets::Assets::Upload.call(asset:, uploaded_file: p8_upload, actor: owner)
    sign_in

    get download_member_shared_secret_asset_path(asset)

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    expect(response.headers["Content-Disposition"]).to include("attachment")
  end

  # CYRA-416: la delega va spiegata nel corpo, la revoca va confermata, «Archivia» non deve sembrare
  # distruttiva e lo scaricamento deve avvisare che resta tracciato.
  describe "CYRA-416: chiarezza delega, conferma revoca, pesi visivi e download tracciato" do
    it "spiega cosa significa delegare in una riga sempre visibile del corpo, non in un tooltip a scomparsa" do
      sign_in
      get member_shared_secret_assets_path

      help = Nokogiri::HTML(response.body).at_css("[data-test='shared-secret-assets-delegation-help']")
      expect(help).to be_present
      expect(help.text).to include(I18n.t("member.secret_assets.delegation_help"))
    end

    # Il menu partiva già sul primo progetto: un clic su «Delega» affidava il file a quello.
    it "il menu della delega parte vuoto e va scelto prima di delegare" do
      asset = create_shared_asset
      project
      sign_in
      get member_shared_secret_assets_path

      select = Nokogiri::HTML(response.body).at_css("select[data-test='shared-secret-delegate-select-#{asset.id}']")
      expect(select["required"]).to be_present
      expect(select.at_css("option")["value"]).to eq("")
    end

    it "revocare una delega chiede conferma nominando progetto, file segreto ed effetto immediato" do
      asset = create_shared_asset
      delegation = asset.delegations.create!(project:, created_by: owner)
      sign_in
      get member_shared_secret_assets_path

      button = Nokogiri::HTML(response.body).at_css("[data-test='shared-secret-undelegate-#{delegation.id}']")
      expect(button).to be_present
      confirm = button.ancestors("form").first["data-turbo-confirm"]
      expect(confirm).to include(project.name)
      expect(confirm).to include(asset.name)
      expect(confirm).to include(I18n.t("member.secret_assets.undelegate_effect"))
    end

    it "la conferma di revoca non contiene mai il valore del segreto" do
      asset = create_shared_asset
      delegation = asset.delegations.create!(project:, created_by: owner)
      sign_in
      get member_shared_secret_assets_path

      confirm = Nokogiri::HTML(response.body)
        .at_css("[data-test='shared-secret-undelegate-#{delegation.id}']").ancestors("form").first["data-turbo-confirm"]
      expect(confirm).not_to include("BEGIN PRIVATE KEY")
    end

    it "il pulsante Archivia non usa lo stile distruttivo, riservato all'eliminazione" do
      asset = create_shared_asset
      sign_in
      get member_shared_secret_assets_path

      button = Nokogiri::HTML(response.body).at_css("[data-test='shared-secret-asset-archive-#{asset.id}']")
      expect(button).to be_present
      expect(button["class"]).not_to include("text-red-600")
    end

    it "avvisa, accanto allo scaricamento, che l'accesso al file resta registrato" do
      asset = create_shared_asset
      sign_in
      get member_shared_secret_assets_path

      note = Nokogiri::HTML(response.body).at_css("[data-test='shared-secret-asset-download-note-#{asset.id}']")
      expect(note).to be_present
      expect(note.text).to include(I18n.t("member.secret_assets.download_note"))
    end
  end

  def create_shared_asset
    organization.secret_assets.create!(project_id: nil, name: "Existing", asset_type: "p8", created_by: owner)
  end

  def p8_upload
    file = Tempfile.new([ "AuthKey_TEST", ".p8" ])
    file.write("-----BEGIN " + "PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "AuthKey_TEST.p8")
  end

  def invalid_p8_upload
    file = Tempfile.new([ "invalid", ".p8" ])
    file.write("not a private key")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "invalid.p8")
  end

  # CYRA-422 — riga permanente di protezione (cifratura, tracciamento, retention) anche sui file dell'organizzazione.
  describe "GET index — protezione (CYRA-422)" do
    it "mostra la riga permanente di protezione dei file dell'organizzazione" do
      sign_in
      get member_shared_secret_assets_path

      expect(response.body).to include('data-test="secret-protection"')
      expect(response.body).to include(I18n.t("member.secret_protection.encryption.shared_files"))
      expect(response.body).to include(I18n.t("member.secret_protection.retention"))
    end
  end
end
