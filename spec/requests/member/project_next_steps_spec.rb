# frozen_string_literal: true

require "rails_helper"

# CYRA-361 — la panoramica di progetto mostrava il problema (dodici errori aperti e nessun ticket, un
# ambiente senza controllo di disponibilità) e non proponeva niente: chi legge doveva andarsi a
# cercare altrove il posto dove agire. Le proposte compaiono solo a condizione vera: una panoramica
# che si accende sempre è rumore.
RSpec.describe "Member::Projects — il passo successivo (CYRA-361)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "con errori aperti e nessun ticket propone di aprirne uno dall'errore più frequente" do
    rare = create(:error_group, project: project, title: "Errore raro", events_count: 2)
    frequent = create(:error_group, project: project, title: "Errore frequente", events_count: 99)

    get member_project_path(project)

    doc = Nokogiri::HTML(response.body)
    step = doc.at_css("[data-test='project-next-step-error-to-ticket']")
    expect(step).to be_present
    expect(step.text).to include("Errore frequente")
    expect(step.text).not_to include(rare.title)
    expect(doc.at_css("[data-test='project-next-step-cta-error-to-ticket']")).to be_present
    expect(response.body).to include(promote_member_monitoring_error_group_path(frequent))
  end

  it "se il progetto ha già dei ticket non propone niente sugli errori" do
    create(:error_group, project: project, events_count: 99)
    create(:ticket, organization: org, project: project)

    get member_project_path(project)

    expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-step-error-to-ticket']")).to be_nil
  end

  # The steps float over the page in a dismissable notice; closing it hides these steps for this
  # project only, and a new step brings the notice back.
  describe "the floating notice" do
    let(:key) { "project_next_steps:#{project.id}:error-to-ticket" }

    before { create(:error_group, project: project, events_count: 9) }

    it "floats the steps in a notice that names this project and these steps" do
      get member_project_path(project)

      notice = Nokogiri::HTML(response.body).at_css("[data-test='project-next-steps']")
      expect(notice["data-ui--floating-notice-key-value"]).to eq(key)
      expect(notice.at_css("[data-test='project-next-step-error-to-ticket']")).to be_present
    end

    it "stays closed once dismissed, and comes back with a step the person has not seen" do
      owner.update!(dismissed_notices: [ key ])

      get member_project_path(project)
      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-steps']")).to be_nil

      owner.update!(dismissed_notices: [ "project_next_steps:#{project.id}:setup-token" ])
      get member_project_path(project)
      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-steps']")).to be_present
    end
  end

  it "senza niente da proporre il riquadro non compare affatto" do
    create(:ticket, organization: org, project: project)

    get member_project_path(project)

    expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-steps']")).to be_nil
  end

  # CYRA-575 — il progetto appena creato era l'unico a non ricevere nessuna proposta: le tre regole
  # esistenti chiedevano dati che un progetto nuovo per definizione non ha. Il consiglio arrivava a
  # chi non ne aveva bisogno e mancava a chi ne avrebbe.
  describe "la prima accensione" do
    it "su un progetto appena creato dice i tre primi passi: ambiente, token, repository" do
      create(:github_installation, organization: org)

      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='project-next-step-setup-environment']")).to be_present
      expect(doc.at_css("[data-test='project-next-step-setup-token']")).to be_present
      expect(doc.at_css("[data-test='project-next-step-setup-repository']")).to be_present
      expect(response.body).to include(member_project_environments_path(project))
      expect(response.body).to include(member_project_tokens_path(project))
      expect(response.body).to include(member_project_github_path(project))
    end

    it "l'ambiente dichiarato toglie il suo passo e lascia gli altri" do
      create(:project_environment, project: project)

      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='project-next-step-setup-environment']")).to be_nil
      expect(doc.at_css("[data-test='project-next-step-setup-token']")).to be_present
    end

    it "il token attivo toglie il suo passo" do
      create(:project_token, project: project)

      get member_project_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-step-setup-token']")).to be_nil
    end

    it "un token revocato non conta come token attivo" do
      create(:project_token, :revoked, project: project)

      get member_project_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-step-setup-token']")).to be_present
    end

    it "il repository collegato toglie il suo passo" do
      create(:github_repository, project: project)

      get member_project_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-step-setup-repository']")).to be_nil
    end

    it "senza l'integrazione GitHub sull'organizzazione non propone di collegare il repository" do
      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='project-next-step-setup-repository']")).to be_nil
      expect(doc.at_css("[data-test='project-next-step-setup-environment']")).to be_present
    end

    # Il passo di accensione è un aiuto finché il progetto non è acceso: su un progetto vivo che di
    # proposito non usa GitHub, "collega il repository" resterebbe acceso per sempre come un rimprovero.
    it "su un progetto che ha già ticket i passi di accensione non compaiono" do
      create(:github_installation, organization: org)
      create(:ticket, organization: org, project: project)

      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='project-next-step-setup-environment']")).to be_nil
      expect(doc.at_css("[data-test='project-next-step-setup-repository']")).to be_nil
    end

    it "su un progetto che riceve già errori i passi di accensione non compaiono" do
      create(:error_group, project: project, events_count: 4)

      get member_project_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-next-step-setup-environment']")).to be_nil
    end

    it "chi non può gestire il progetto non legge passi che non potrebbe compiere" do
      create(:github_installation, organization: org)
      viewer = create(:account)
      create(:membership, account: viewer, organization: org, role: :member)
      create(:project_membership, account: viewer, project: project)
      post login_path, params: { email: viewer.email, password: "Secret123!" }

      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='project-next-step-setup-environment']")).to be_nil
      expect(doc.at_css("[data-test='project-next-step-setup-token']")).to be_nil
      expect(doc.at_css("[data-test='project-next-step-setup-repository']")).to be_nil
    end
  end

  # CYRA-575 — la card dei ticket vuota diceva "Ancora nessun ticket" e nient'altro: nessun modo di
  # crearne uno da lì, proprio dove chi legge ha appena scoperto che non ce ne sono.
  describe "la card dei ticket vuota" do
    it "spiega cosa manca e offre il pulsante per creare il primo ticket" do
      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      empty = doc.at_css("[data-test='project-tickets-empty']")
      expect(empty).to be_present
      expect(empty.at_css("[data-test='empty-body']")).to be_present
      expect(empty.at_css("[data-test='empty-example']")).to be_present
      expect(doc.at_css("[data-test='project-tickets-empty-new']")).to be_present
      expect(response.body).to include(new_member_ticket_path(project_id: project.id))
    end

    it "con dei ticket la card mostra la tabella, non lo stato vuoto" do
      create(:ticket, organization: org, project: project)

      get member_project_path(project)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='project-tickets-empty']")).to be_nil
    end
  end
end
