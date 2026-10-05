# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::SavedViews", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:other) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:membership, account: other, organization: org, role: :member)
  end

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "salva una vista ticket coi filtri correnti e reindirizza all'index ticket" do
      sign_in(account)
      expect do
        post member_saved_views_path,
             params: { resource_type: "tickets", name: "Aperti", status_id: [ "s1" ], q: "login" }
      end.to change(SavedView, :count).by(1)

      view = SavedView.last
      expect(view.account).to eq(account)
      expect(view.organization).to eq(org)
      expect(view.resource_type).to eq("tickets")
      expect(view.filters).to include("status_id" => [ "s1" ], "q" => "login")
      expect(response).to redirect_to(%r{/member/tickets})
    end

    it "salva una vista error_groups con le sue chiavi e reindirizza al suo index" do
      sign_in(account)
      post member_saved_views_path,
           params: { resource_type: "error_groups", name: "Gravi", level: [ "error" ], q: "boom", kind: [ "bug" ] }

      view = SavedView.last
      expect(view.resource_type).to eq("error_groups")
      expect(view.filters.keys).to contain_exactly("level", "q") # kind non è filtro di error_groups
      expect(response).to redirect_to(%r{/member/monitoring/error})
    end

    it "il sort corrente viaggia con la vista (persistito e riapplicato nel redirect)" do
      sign_in(account)
      post member_saved_views_path,
           params: { resource_type: "tickets", name: "Per titolo", sort: "-title", q: "crash" }

      view = SavedView.last
      expect(view.filters).to include("sort" => "-title", "q" => "crash")
      expect(response.location).to include("sort=-title")
    end

    it "salva una vista servers e reindirizza al suo index" do
      sign_in(account)
      expect do
        post member_saved_views_path,
             params: { resource_type: "servers", name: "Fleet", status: [ "down" ], q: "web" }
      end.to change(SavedView, :count).by(1)

      view = SavedView.last
      expect(view.resource_type).to eq("servers")
      expect(view.filters).to include("status" => [ "down" ], "q" => "web")
      expect(response).to redirect_to(%r{/member/monitoring/servers})
    end

    it "salva una vista cron_monitors e reindirizza al suo index" do
      sign_in(account)
      expect do
        post member_saved_views_path,
             params: { resource_type: "cron_monitors", name: "Silenti", status: [ "missing" ], q: "backup" }
      end.to change(SavedView, :count).by(1)

      view = SavedView.last
      expect(view.resource_type).to eq("cron_monitors")
      expect(view.filters).to include("status" => [ "missing" ], "q" => "backup")
      expect(response).to redirect_to(%r{/member/monitoring/cron})
    end

    it "salva una vista ideas e reindirizza all'elenco delle idee (CYRA-224)" do
      sign_in(account)
      expect do
        post member_saved_views_path,
             params: { resource_type: "ideas", name: "Da valutare", status: "new", q: "chat" }
      end.to change(SavedView, :count).by(1)

      view = SavedView.last
      expect(view.resource_type).to eq("ideas")
      expect(view.filters).to include("status" => "new", "q" => "chat")
      expect(response).to redirect_to(%r{/member/ideas})
    end

    it "salva una vista documents (risorsa nested) col project_id e reindirizza al suo index nested" do
      project = create(:project, organization: org)
      create(:project_membership, account: account, project: project)
      sign_in(account)

      post member_saved_views_path,
           params: { resource_type: "documents", name: "Legali", project_id: project.id, tag: [ "legal" ], q: "iva" }

      view = SavedView.last
      expect(view.resource_type).to eq("documents")
      expect(view.filters).to include("project_id" => project.id, "tag" => [ "legal" ], "q" => "iva")
      expect(response).to redirect_to(member_project_documents_path(project, tag: [ "legal" ], q: "iva"))
    end

    it "vista documents senza project_id → save fallisce (nessun 500), redirect con alert" do
      sign_in(account)
      expect do
        post member_saved_views_path, params: { resource_type: "documents", name: "Rotta", tag: [ "legal" ] }
      end.not_to change(SavedView, :count)
      expect(response).to have_http_status(:found)
    end

    it "without filters keeps only how the list looks: grouping and sort (CYRA-924)" do
      sign_in(account)
      post member_saved_views_path,
           params: { resource_type: "uptime", name: "Flat", include_filters: "0",
                     view: "table", sort: "monitor", range: "7d", status: [ "down" ], q: "api" }

      expect(SavedView.find_by!(name: "Flat").filters).to eq("view" => "table", "sort" => "monitor")
    end

    it "with filters keeps the filters too (CYRA-924)" do
      sign_in(account)
      post member_saved_views_path,
           params: { resource_type: "uptime", name: "Down", include_filters: "1", view: "table", status: [ "down" ] }

      expect(SavedView.find_by!(name: "Down").filters).to eq("view" => "table", "status" => [ "down" ])
    end

    it "resource_type sconosciuto → 404 (nessuna vista creata)" do
      sign_in(account)
      expect do
        post member_saved_views_path, params: { resource_type: "bogus", name: "X" }
      end.not_to change(SavedView, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "nome mancante → save fallisce, redirect all'index con alert (nessuna vista creata)" do
      sign_in(account)
      expect do
        post member_saved_views_path, params: { resource_type: "tickets", name: "  " }
      end.not_to change(SavedView, :count)
      expect(response).to redirect_to(%r{/member/tickets})
    end

    it "non autenticato → redirect login" do
      post member_saved_views_path, params: { resource_type: "tickets", name: "X" }
      expect(response).to redirect_to(login_path)
    end
  end

  describe "DELETE destroy" do
    it "elimina la propria vista e reindirizza all'index della risorsa" do
      sign_in(account)
      view = create(:saved_view, account: account, organization: org, resource_type: "error_groups", name: "Mine")
      expect { delete member_saved_view_path(view) }.to change(SavedView, :count).by(-1)
      expect(response).to redirect_to(%r{/member/monitoring/error})
    end

    it "elimina una vista ideas e reindirizza all'elenco delle idee (CYRA-224)" do
      sign_in(account)
      view = create(:saved_view, account: account, organization: org, resource_type: "ideas", name: "Mine")
      expect { delete member_saved_view_path(view) }.to change(SavedView, :count).by(-1)
      expect(response).to redirect_to(%r{/member/ideas})
    end

    it "BOLA: la vista di un altro account → 404" do
      sign_in(account)
      foreign = create(:saved_view, account: other, organization: org, name: "Theirs")
      delete member_saved_view_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "vista documents (nested): destroy reindirizza all'index del progetto salvato" do
      project = create(:project, organization: org)
      sign_in(account)
      view = create(:saved_view, account: account, organization: org, resource_type: "documents",
                    name: "Legali", filters: { "project_id" => project.id, "tag" => [ "legal" ] })
      expect { delete member_saved_view_path(view) }.to change(SavedView, :count).by(-1)
      expect(response).to redirect_to(member_project_documents_path(project))
    end
  end

  # CYRA-395 — il pannello vuoto diceva «nessuna vista» e offriva di aggiungerne «un'altra»: non
  # spiegava cosa venga salvato né a cosa serva, e la funzione restava inutilizzata.
  describe "il pannello vuoto si spiega e propone due tagli pronti" do
    before { Types::InstallDefaults.call(organization: org) }

    it "dice cosa viene salvato e non propone di aggiungerne un'altra" do
      sign_in(account)
      get list_member_tickets_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='saved-views-empty']").text).to include(I18n.t("shared.saved_views.empty_hint"))
      expect(pagina.at_css("[data-test='saved-view-add']").text.strip).to eq(I18n.t("shared.saved_views.save_current"))
      expect(pagina.at_css("[data-test='saved-view-add']").text).not_to include(I18n.t("shared.saved_views.add"))
    end

    it "offre due viste già pronte, con i filtri dentro il collegamento" do
      sign_in(account)
      get list_member_tickets_path

      pagina = Nokogiri::HTML(response.body)
      mie = pagina.at_css("[data-test='saved-view-preset-mine']")
      alta = pagina.at_css("[data-test='saved-view-preset-high_open']")
      expect(mie).to be_present
      expect(mie["href"]).to include("assignee_id")
      expect(alta).to be_present
      expect(alta["href"]).to include("priority_id")
    end

    it "con una vista salvata i tagli pronti lasciano il posto alle sue" do
      create(:saved_view, account: account, organization: org, resource_type: "tickets", name: "La mia")

      sign_in(account)
      get list_member_tickets_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='saved-view-preset-mine']")).to be_nil
      expect(pagina.text).to include("La mia")
    end
  end
end
