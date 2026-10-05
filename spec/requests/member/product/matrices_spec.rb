# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Product::Matrices", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org, name: "DriverOne") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def grant(account, keys)
    Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: keys, actor: owner)
  end

  # Progetto del prodotto che dichiara la piattaforma indicata.
  def project_on(platform)
    create(:project, organization: org, group: group).tap do |project|
      Connections::ProjectPlatform.create!(project: project, platform: platform)
    end
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_product_matrices_path
      expect(response).to redirect_to(login_path)
    end

    it "membro senza permesso → redirect (gate product_features.view)" do
      sign_in(member)
      get member_product_matrices_path
      expect(response).to redirect_to(root_path)
    end

    it "con product_features.view → 200 e mostra i prodotti visibili" do
      grant(member, [ "product_features.view", "project_groups.view" ])
      create(:group_membership, account: member, group: group)
      sign_in(member)

      get member_product_matrices_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("DriverOne")
    end

    it "l'owner vede i conteggi di categorie e funzionalità" do
      category = create(:product_category, group: group, organization: org)
      create(:product_feature, category: category, organization: org)
      sign_in(owner)

      get member_product_matrices_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("product-matrix-row-#{group.id}")
    end

    it "non elenca i prodotti non visibili all'account" do
      other = create(:group, organization: org, name: "Invisibile")
      grant(member, [ "product_features.view" ])
      sign_in(member)

      get member_product_matrices_path

      expect(response.body).not_to include(ERB::Util.html_escape(other.name))
    end

    it "mostra la spiegazione della matrice in testata, non solo dentro un'icona" do
      sign_in(owner)

      get member_product_matrices_path

      expect(response.body).to include("product-matrices-header-subtitle")
      expect(response.body).to include(I18n.t("member.product.matrices.help"))
    end

    it "mostra un esempio di riga già compilata" do
      sign_in(owner)

      get member_product_matrices_path

      expect(response.body).to include("product-matrices-intro")
    end

    it "per un prodotto vuoto invita a creare la prima categoria invece di mostrare zeri" do
      group # il gruppo DriverOne esiste ma non ha categorie né funzionalità
      sign_in(owner)

      get member_product_matrices_path

      expect(response.body).to include("product-matrix-empty-cta-#{group.id}")
      expect(response.body).to include(new_member_product_category_path(matrix_id: group.id))
    end

    it "a chi può solo guardare non offre l'invito ad agire sulla riga vuota" do
      grant(member, [ "product_features.view" ])
      create(:group_membership, account: member, group: group)
      sign_in(member)

      get member_product_matrices_path

      expect(response.body).not_to include("product-matrix-empty-cta-#{group.id}")
      expect(response.body).to include("product-matrix-empty-hint-#{group.id}")
    end

    it "mostra la copertura coperte/attese per piattaforma di un prodotto con funzionalità" do
      web = create(:platform, organization: org, label: "Web")
      covered = create(:product_feature, category: create(:product_category, group: group, organization: org), organization: org)
      expected_only = create(:product_feature, category: covered.category, organization: org)
      create(:feature_platform, feature: covered, platform: web,
                                status: create(:feature_status, :available, organization: org))
      create(:feature_platform, feature: expected_only, platform: web,
                                status: create(:feature_status, organization: org)) # planned → attesa ma non coperta
      sign_in(owner)

      get member_product_matrices_path

      start = response.body.index(%(data-test="product-matrix-coverage-#{group.id}-#{web.id}"))
      expect(start).not_to be_nil
      chip = response.body[start, 400]
      expect(chip).to include("Web")
      expect(chip).to include("1/2")
    end

    it "non conta come attesa una funzionalità «non applicabile» su una piattaforma" do
      web = create(:platform, organization: org, label: "Web")
      covered = create(:product_feature, category: create(:product_category, group: group, organization: org), organization: org)
      excluded = create(:product_feature, category: covered.category, organization: org)
      create(:feature_platform, feature: covered, platform: web,
                                status: create(:feature_status, :available, organization: org))
      create(:feature_platform, feature: excluded, platform: web,
                                status: create(:feature_status, :not_applicable, organization: org))
      sign_in(owner)

      get member_product_matrices_path

      start = response.body.index(%(data-test="product-matrix-coverage-#{group.id}-#{web.id}"))
      chip = response.body[start, 400]
      expect(chip).to include("1/1") # la casella «non applicabile» non entra nel denominatore
    end

    it "regge molti prodotti con copertura senza N+1" do
      allow_n_plus_one do
        web = create(:platform, organization: org, label: "Web")
        status = create(:feature_status, :available, organization: org)
        3.times do
          other = create(:group, organization: org)
          category = create(:product_category, group: other, organization: org)
          2.times do
            feature = create(:product_feature, category: category, organization: org)
            create(:feature_platform, feature: feature, platform: web, status: status)
          end
        end
        sign_in(owner)
      end

      get member_product_matrices_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("product-matrices-body")
    end
  end

  describe "GET show" do
    it "404 su un prodotto non visibile (anti-BOLA)" do
      grant(member, [ "product_features.view" ])
      sign_in(member)

      get member_product_matrix_path(group)

      expect(response).to have_http_status(:not_found)
    end

    it "404 su un prodotto di un'altra organizzazione" do
      foreign = create(:group, organization: create(:organization))
      sign_in(owner)

      get member_product_matrix_path(foreign)

      expect(response).to have_http_status(:not_found)
    end

    it "mostra categorie, funzionalità e colonne" do
      platform = create(:platform, organization: org, label: "Web")
      project_on(platform)
      category = create(:product_category, group: group, organization: org, name: "Auth")
      create(:product_feature, category: category, organization: org, name: "2FA")
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Auth", "2FA", "Web")
    end

    it "mostra come colonna una piattaforma senza progetti, se una cella la usa già" do
      # Il caso che rende la matrice utile in anticipo: l'app iPhone non esiste ancora.
      planned = create(:platform, organization: org, label: "iOS")
      category = create(:product_category, group: group, organization: org)
      feature = create(:product_feature, category: category, organization: org)
      create(:feature_platform, feature: feature, platform: planned,
                                status: create(:feature_status, organization: org))
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("iOS")
    end

    it "conta le caselle disponibili senza versione" do
      platform = create(:platform, organization: org)
      project_on(platform)
      category = create(:product_category, group: group, organization: org)
      feature = create(:product_feature, category: category, organization: org)
      create(:feature_platform, feature: feature, platform: platform,
                                status: create(:feature_status, :available, organization: org))
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("product-matrix-count-missing-release")
    end

    it "mostra la versione e il link al tag quando la casella la indica" do
      platform = create(:platform, organization: org)
      project = project_on(platform)
      release = create(:release, project: project, version: "2.1.0",
                                 git_tag_url: "https://github.com/acme/app/releases/tag/v2.1.0")
      category = create(:product_category, group: group, organization: org)
      feature = create(:product_feature, category: category, organization: org)
      create(:feature_platform, feature: feature, platform: platform, release: release,
                                status: create(:feature_status, :available, organization: org))
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("2.1.0", release.git_tag_url)
      expect(response.body).not_to include("product-matrix-count-missing-release")
    end

    it "non annida il link al rilascio dentro il link di modifica della casella" do
      # Un <a> dentro un <a> è HTML invalido: il browser lo espelle dal link esterno e il link al
      # rilascio semplicemente non viene reso. Non si vede nel body grezzo, solo nel DOM.
      platform = create(:platform, organization: org)
      project = project_on(platform)
      release = create(:release, project: project, version: "3.0.0",
                                 git_tag_url: "https://github.com/acme/app/releases/tag/v3.0.0")
      category = create(:product_category, group: group, organization: org)
      feature = create(:product_feature, category: category, organization: org)
      create(:feature_platform, feature: feature, platform: platform, release: release,
                                status: create(:feature_status, :available, organization: org))
      sign_in(owner)

      get member_product_matrix_path(group)

      start = response.body.index(%(data-test="product-cell-#{feature.id}-#{platform.id}"))
      edit_link = response.body[start...response.body.index("</a>", start)]
      expect(edit_link).not_to include(release.git_tag_url)
      expect(response.body).to include(release.git_tag_url)
    end

    it "mostra il banner quando non c'è nessuna piattaforma" do
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("product-matrix-no-platforms")
    end

    it "senza permesso di gestione non mostra le azioni di modifica" do
      grant(member, [ "product_features.view" ])
      create(:group_membership, account: member, group: group)
      category = create(:product_category, group: group, organization: org)
      create(:product_feature, category: category, organization: org)
      sign_in(member)

      get member_product_matrix_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("product-category-new")
      expect(response.body).not_to include("product-feature-menu-")
    end

    it "non offre il link al macro-progetto a chi non può aprirlo" do
      # Il bottone porterebbe a un rimbalzo: chi ha solo la matrice non ha project_groups.view.
      grant(member, [ "product_features.manage" ])
      create(:group_membership, account: member, group: group)
      sign_in(member)

      get member_product_matrix_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("product-matrix-open-group")
    end

    it "offre il link al macro-progetto a chi può aprirlo" do
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("product-matrix-open-group")
    end

    it "con product_features.manage mostra le azioni di modifica" do
      sign_in(owner)

      get member_product_matrix_path(group)

      expect(response.body).to include("product-category-new")
    end

    it "regge una matrice piena senza N+1" do
      # Il setup crea 36 celle: ognuna valida la coerenza della sua release con una EXISTS, query
      # per-record di fixture che non è un N+1 di produzione. La RICHIESTA resta sotto scansione:
      # è lì che Prosopite deve fallire se le query crescono con righe e colonne.
      allow_n_plus_one do
        platforms = Array.new(3) { create(:platform, organization: org) }
        project = create(:project, organization: org, group: group)
        platforms.each { |p| Connections::ProjectPlatform.create!(project: project, platform: p) }
        status = create(:feature_status, :available, organization: org)
        release = create(:release, project: project)
        3.times do
          category = create(:product_category, group: group, organization: org)
          4.times do
            feature = create(:product_feature, category: category, organization: org,
                                               knowledge_page: create(:knowledge_page, organization: org))
            platforms.each do |platform|
              create(:feature_platform, feature: feature, platform: platform, status: status, release: release)
            end
          end
        end
        sign_in(owner)
      end

      get member_product_matrix_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("product-matrix-body")
    end
  end

  # CYRA-924 — deleting a category or a feature asks in a dialog that names it (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog for the category and one for the feature" do
      category = create(:product_category, group: group, organization: org, name: "Pagamenti")
      feature = create(:product_feature, category: category, organization: org, name: "Rimborso")
      sign_in(owner)

      get member_product_matrix_path(group)

      html = Nokogiri::HTML(response.body)
      category_dialog = html.at_css("dialog[data-test='product-category-delete-dialog-#{category.id}']")
      expect(category_dialog.text).to include(I18n.t("member.product.categories.delete_dialog.title", name: "Pagamenti"))
      expect(category_dialog.at_css("form")["action"]).to eq(member_product_category_path(category))
      feature_dialog = html.at_css("dialog[data-test='product-feature-delete-dialog-#{feature.id}']")
      expect(feature_dialog.text).to include(I18n.t("member.product.features.delete_dialog.title", name: "Rimborso"))
      expect(feature_dialog.at_css("form")["action"]).to eq(member_product_feature_path(feature))
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
