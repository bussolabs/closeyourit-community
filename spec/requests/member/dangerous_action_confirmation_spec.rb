# frozen_string_literal: true

require "rails_helper"

# CYRA-728 — il segno `dangerous` del catalogo è esecutivo: nell'area utenti un'azione pericolosa
# senza conferma non parte, e chi la conferma lascia una riga nel registro dei permessi.
RSpec.describe "Member — conferma delle azioni pericolose", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: organization, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "un'eliminazione (chiave pericolosa)" do
    let!(:project) { create(:project, organization: organization) }

    it "senza conferma → 422 e il progetto resta dov'era" do
      sign_in(owner)

      expect { delete member_project_path(project) }.not_to change(Projects::Project, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("member.confirmation_required.title"))
    end

    it "senza conferma la pagina offre di rifare la stessa azione confermandola" do
      sign_in(owner)
      delete member_project_path(project)

      expect(response.body).to include('data-test="dangerous-action-confirmation"')
      expect(response.body).to include('data-test="dangerous-action-confirm"')
    end

    it "con la conferma l'azione parte" do
      sign_in(owner)

      expect { delete member_project_path(project), params: { confirm: "1" } }
        .to change(Projects::Project, :count).by(-1)
    end

    it "la conferma resta scritta nel registro dei permessi" do
      sign_in(owner)

      expect { delete member_project_path(project), params: { confirm: "1" } }
        .to change { Authorization::Event.where(action: "dangerous_action_confirmed").count }.by(1)

      evento = Authorization::Event.where(action: "dangerous_action_confirmed").last
      expect(evento.organization).to eq(organization)
      expect(evento.actor).to eq(owner)
      expect(evento.data).to include("key" => "projects.delete", "method" => "DELETE")
    end

    it "un no scritto non vale come conferma" do
      sign_in(owner)

      expect { delete member_project_path(project), params: { confirm: "0" } }
        .not_to change(Projects::Project, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "una chiave che il catalogo NON segna pericolosa" do
    let!(:project) { create(:project, organization: organization) }

    it "non chiede niente: la modifica passa come sempre" do
      sign_in(owner)

      patch member_project_path(project), params: { name: "Rinominato" }

      expect(response).not_to have_http_status(:unprocessable_content)
      expect(project.reload.name).to eq("Rinominato")
    end
  end

  describe "moderare quello che ha scritto un altro" do
    it "il proprio commento si cancella senza cerimonie" do
      progetto = create(:project, organization: organization)
      ticket = create(:ticket, organization: organization, project: progetto)
      commento = create(:ticket_comment, ticket: ticket, author: owner)
      sign_in(owner)

      expect { delete member_ticket_comment_path(ticket, commento) }
        .to change(Ticketing::Comment, :count).by(-1)
    end

    it "quello di un altro no: senza conferma resta dov'è" do
      progetto = create(:project, organization: organization)
      ticket = create(:ticket, organization: organization, project: progetto)
      altro = create(:account)
      create(:membership, account: altro, organization: organization, role: :member)
      commento = create(:ticket_comment, ticket: ticket, author: altro)
      sign_in(owner)

      expect { delete member_ticket_comment_path(ticket, commento) }
        .not_to change(Ticketing::Comment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "chi chiede JSON" do
    let!(:project) { create(:project, organization: organization) }

    it "riceve l'envelope, non una pagina: un comando che parte da un fetch deve poter leggere il no" do
      sign_in(owner)

      delete member_project_path(project), headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-CONFIRM-001")
    end
  end

  describe "un POST che non scrive niente" do
    it "l'anteprima della fusione non chiede conferma: è essa stessa la schermata di conferma" do
      progetto = create(:project, organization: organization)
      primo = create(:error_group, project: progetto)
      secondo = create(:error_group, project: progetto)
      sign_in(owner)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ primo.id, secondo.id ] }

      expect(response).to have_http_status(:ok)
    end

    it "e la fusione vera, che non si annulla, la pretende" do
      progetto = create(:project, organization: organization)
      primo = create(:error_group, project: progetto)
      secondo = create(:error_group, project: progetto)
      sign_in(owner)

      post merge_member_monitoring_error_groups_path, params: { primary_id: primo.id, ids: [ primo.id, secondo.id ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Errors::Group.exists?(secondo.id)).to be(true)
    end
  end

  describe "aprire una pagina" do
    it "leggere non è eseguire: una index gated da chiave pericolosa si apre senza conferma" do
      sign_in(owner)

      get member_roles_path

      expect(response).to have_http_status(:ok)
    end

    it "e non lascia nessuna riga nel registro" do
      sign_in(owner)

      expect { get member_roles_path }
        .not_to change { Authorization::Event.where(action: "dangerous_action_confirmed").count }
    end
  end
end
