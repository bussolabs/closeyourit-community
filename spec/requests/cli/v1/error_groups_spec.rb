# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::ErrorGroups", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    get "/cli/v1/projects/#{project.id}/error_groups"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vede tutto + triage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i gruppi del progetto e meta" do
      group = create(:error_group, project:)
      get "/cli/v1/projects/#{project.id}/error_groups", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |g| g["id"] }
      expect(ids).to include(group.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "show → 200" do
      group = create(:error_group, project:)
      get "/cli/v1/projects/#{project.id}/error_groups/#{group.id}", headers: headers
      expect(response.parsed_body["data"]["id"]).to eq(group.id)
    end

    it "index filtra per status quando il param è valido (ramo statuses.key?)" do
      open_group = create(:error_group, project:, status: :unresolved)
      done_group = create(:error_group, project:, status: :resolved)
      get "/cli/v1/projects/#{project.id}/error_groups", params: { status: "resolved" }, headers: headers

      ids = response.parsed_body["data"].map { |g| g["id"] }
      expect(ids).to include(done_group.id)
      expect(ids).not_to include(open_group.id)
    end

    it "resolve (PUT resolution) → 200, status resolved" do
      group = create(:error_group, project:, status: :unresolved)
      put "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution", headers: headers
      expect(response).to have_http_status(:ok)
      expect(group.reload.status).to eq("resolved")
    end

    it "reopen (DELETE resolution) → unresolved" do
      group = create(:error_group, project:, status: :resolved)
      delete "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution", headers: headers
      expect(group.reload.status).to eq("unresolved")
    end

    it "mute (PUT mute) → ignored" do
      group = create(:error_group, project:, status: :unresolved)
      put "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/mute", headers: headers
      expect(group.reload.status).to eq("ignored")
    end

    it "unmute (DELETE mute) → unresolved" do
      group = create(:error_group, project:, status: :ignored)
      delete "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/mute", headers: headers
      expect(response).to have_http_status(:ok)
      expect(group.reload.status).to eq("unresolved")
    end

    it "gruppo di un'altra org → 404 (anti-BOLA)" do
      other = create(:error_group)
      get "/cli/v1/projects/#{other.project_id}/error_groups/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza errors.triage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "può leggere (la visibilità è il gate)" do
      create(:error_group, project:)
      get "/cli/v1/projects/#{project.id}/error_groups", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "NON può fare triage → 403 R403-CLIAUTH-002" do
      group = create(:error_group, project:, status: :unresolved)
      put "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(group.reload.status).to eq("unresolved")
    end

    # CYRA-192/CYRA-153: fondere, dividere ed eliminare hanno una chiave PROPRIA (errors.destroy),
    # perché toccano la struttura del grouping. Chi non ha nemmeno il triage ovviamente non le tocca.
    it "NON può fondere, dividere né eliminare → 403 e i gruppi restano" do
      primary = create(:error_group, project:)
      source = create(:error_group, project:)
      event = create(:error_event, group: primary, project:)

      post "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}/merge",
           params: { ids: [ source.id ] }, headers: headers
      expect(response).to have_http_status(:forbidden)

      post "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}/split",
           params: { event_ids: [ event.id ] }, headers: headers
      expect(response).to have_http_status(:forbidden)

      delete "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(Errors::Group.where(id: [ primary.id, source.id ]).count).to eq(2)
    end

    # CYRA-153: assegnare ha la sua chiave (errors.assign). Chi non ce l'ha non tocca l'assegnatario.
    it "NON può assegnare → 403 e l'assegnatario resta invariato" do
      group = create(:error_group, project:)

      patch "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/assign",
            params: { assignee_id: account.id }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(group.reload.assignee_id).to be_nil
    end
  end

  # CYRA-192 — chiudere documentando, fondere, eliminare: le tre azioni chieste anche da terminale.
  describe "risoluzione documentata, fusione ed eliminazione" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "risolve annotando causa e rimedio, e la lettura li restituisce" do
      group = create(:error_group, project:, status: :unresolved)

      put "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution",
          params: { cause: "Solid Cable su SQLite andava in lock", fix: "Guard anti-ricorsione nell'SDK" },
          headers: headers

      expect(response).to have_http_status(:ok)
      expect(group.reload).to have_attributes(
        status: "resolved",
        resolution_cause: "Solid Cable su SQLite andava in lock",
        resolution_fix: "Guard anti-ricorsione nell'SDK"
      )

      get "/cli/v1/projects/#{project.id}/error_groups/#{group.id}", headers: headers
      expect(response.parsed_body["data"]["resolution_cause"]).to include("SQLite")
    end

    it "riaprendo cancella la spiegazione: un gruppo riaperto non è più risolto" do
      group = create(:error_group, project:, status: :resolved,
                                   resolution_cause: "vecchia causa", resolution_fix: "vecchio rimedio")

      delete "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution", headers: headers

      expect(group.reload).to have_attributes(status: "unresolved", resolution_cause: nil, resolution_fix: nil)
    end

    it "fonde i gruppi indicati nel primario e li fa sparire" do
      primary = create(:error_group, project:, events_count: 4)
      source = create(:error_group, project:, events_count: 6)
      create(:error_event, group: source, project:)

      post "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}/merge",
           params: { confirm: "1", ids: [ source.id ] }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["meta"]["merged"]).to eq(1)
      expect(primary.reload.events_count).to eq(10)
      expect(primary.events.count).to eq(1)
      expect(Errors::Group.exists?(source.id)).to be(false)
    end

    # Anti-BOLA: lo scope è già gattato al progetto, quindi un gruppo altrui non viene nemmeno
    # trovato — la fusione si ferma prima di toccare qualsiasi cosa.
    it "non fonde un gruppo di un altro progetto" do
      primary = create(:error_group, project:)
      estraneo = create(:error_group)

      post "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}/merge",
           params: { ids: [ estraneo.id ] }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(Errors::Group.exists?(estraneo.id)).to be(true)
    end

    it "elimina il gruppo con le sue occorrenze" do
      group = create(:error_group, project:, status: :resolved)
      create(:error_event, group:, project:)

      delete "/cli/v1/projects/#{project.id}/error_groups/#{group.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(Errors::Group.exists?(group.id)).to be(false)
      expect(Errors::Event.where(group_id: group.id)).to be_empty
    end

    it "non elimina un gruppo di un altro progetto → 404" do
      estraneo = create(:error_group)

      delete "/cli/v1/projects/#{project.id}/error_groups/#{estraneo.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Errors::Group.exists?(estraneo.id)).to be(true)
    end

    # Tutto-o-niente anche dal canale: fondere i validi e scartare gli altri in silenzio lascerebbe
    # l'utente convinto di aver unito più gruppi di quelli davvero uniti, senza poter tornare indietro.
    it "con una lista che contiene un gruppo altrui non fonde niente" do
      primary = create(:error_group, project:, events_count: 3)
      buono = create(:error_group, project:, events_count: 4)
      estraneo = create(:error_group)

      post "/cli/v1/projects/#{project.id}/error_groups/#{primary.id}/merge",
           params: { ids: [ buono.id, estraneo.id ] }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(Errors::Group.where(id: [ buono.id, estraneo.id ]).count).to eq(2)
      expect(primary.reload.events_count).to eq(3)
    end

    # CYRA-153: assegnazione da terminale.
    describe "assegnazione di un errore" do
      def member_account
        create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
      end

      it "assegna un membro dell'org → 200 e assignee nel payload" do
        group = create(:error_group, project:)
        assignee = member_account

        patch "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/assign",
              params: { assignee_id: assignee.id }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(group.reload.assignee_id).to eq(assignee.id)
        expect(response.parsed_body["data"]["assignee"]).to include("id" => assignee.id, "name" => assignee.name)
      end

      it "assignee_id vuoto → disassegna" do
        group = create(:error_group, project:, assignee: member_account)

        patch "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/assign",
              params: { assignee_id: "" }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(group.reload.assignee_id).to be_nil
      end

      # Anti-BOLA: un account fuori org non diventa assegnatario.
      it "un account fuori org non diventa assegnatario" do
        outsider = create(:account)
        group = create(:error_group, project:)

        patch "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/assign",
              params: { assignee_id: outsider.id }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(group.reload.assignee_id).to be_nil
      end
    end

    # CYRA-153: divisione di un gruppo da terminale.
    describe "divisione di un gruppo" do
      it "estrae le occorrenze indicate in un nuovo gruppo → 200" do
        group = create(:error_group, project:, events_count: 2)
        keep = create(:error_event, group:, project:)
        move = create(:error_event, group:, project:)

        post "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/split",
             params: { confirm: "1", event_ids: [ move.id ] }, headers: headers

        expect(response).to have_http_status(:ok)
        new_id = response.parsed_body["data"]["id"]
        expect(new_id).not_to eq(group.id)
        expect(move.reload.group_id).to eq(new_id)
        expect(keep.reload.group_id).to eq(group.id)
      end

      # Tutto-o-niente + anti-BOLA: un'occorrenza di un altro gruppo ferma la divisione.
      it "con un'occorrenza di un altro gruppo non divide niente → 422" do
        group = create(:error_group, project:)
        mine = create(:error_event, group:, project:)
        stranger = create(:error_event, project:)

        post "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/split",
             params: { event_ids: [ mine.id, stranger.id ] }, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(mine.reload.group_id).to eq(group.id)
      end
    end
  end

  # La chiave errors.destroy è separata da errors.triage proprio per questo: il ruolo "Triager"
  # smista, non cancella. Se le due azioni condividessero il gate, chiunque abbia già quel ruolo si
  # ritroverebbe in mano una cancellazione irreversibile senza che nessuno gliel'abbia concessa.
  describe "un Triager non può distruggere" do
    let(:triager) { create(:account) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(triager)}" } }

    before do
      create(:membership, account: triager, organization:, role: :member)
      create(:project_membership, account: triager, project:)
      role = create(:role, organization:, name: "Triager")
      create(:role_permission, role:, permission_key: "errors.triage")
      create(:account_role, account: triager, role:, organization:)
    end

    it "risolve ma non fonde né elimina" do
      group = create(:error_group, project:, status: :unresolved)
      altro = create(:error_group, project:)

      put "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/resolution",
          params: { cause: "x", fix: "y" }, headers: headers
      expect(response).to have_http_status(:ok)

      post "/cli/v1/projects/#{project.id}/error_groups/#{group.id}/merge",
           params: { ids: [ altro.id ] }, headers: headers
      expect(response).to have_http_status(:forbidden)

      delete "/cli/v1/projects/#{project.id}/error_groups/#{group.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(Errors::Group.where(id: [ group.id, altro.id ]).count).to eq(2)
    end
  end
end
