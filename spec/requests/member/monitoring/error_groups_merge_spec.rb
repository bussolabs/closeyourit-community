# frozen_string_literal: true

require "rails_helper"

# CYRA-192 — la superficie web delle tre azioni che il ticket chiede: fondere N gruppi in uno (con
# una conferma che dice davvero COSA si sta fondendo, perché non si torna indietro), chiudere
# scrivendo causa e rimedio, eliminare un gruppo.
RSpec.describe "Member::Monitoring::ErrorGroups merge, risoluzione e eliminazione", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Un membro semplice con SOLO errors.triage: è il ruolo «Triager» dei default, che smista ma non
  # cancella. Serve a provare che il gate della fusione e dell'eliminazione è un'altra chiave.
  def triager
    account = create(:account)
    create(:membership, account:, organization: org, role: :member)
    create(:project_membership, account:, project:)
    role = create(:role, organization: org, name: "Triager")
    create(:role_permission, role:, permission_key: "errors.triage")
    create(:account_role, account:, role:, organization: org)
    account
  end

  describe "POST merge_preview — la conferma che mostra cosa si sta fondendo" do
    before { sign_in(owner) }

    it "elenca i gruppi selezionati con titolo, punto del codice e conteggi" do
      primary = create(:error_group, project:, title: "RuntimeError: boom", events_count: 40)
      source  = create(:error_group, project:, title: "RuntimeError: boom", culprit: "App::Other#call", events_count: 2)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ primary.id, source.id ] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("App::Other#call")
      expect(response.body).to include(primary.id, source.id)
    end

    # Il primario è una SCELTA, non il primo della lista: è il gruppo che sopravvive e si tiene tutto.
    it "propone di scegliere quale gruppo resta" do
      a = create(:error_group, project:)
      b = create(:error_group, project:)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ a.id, b.id ] }

      expect(response.body).to include("primary_id")
    end

    it "un gruppo solo non è una fusione → torna all'elenco spiegando" do
      only = create(:error_group, project:)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ only.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
    end

    # Il fingerprint è unico PER PROGETTO e le occorrenze denormalizzano project_id: fondere fra
    # progetti sposterebbe i dati di un tenant sotto un altro. Si dice prima di far confermare.
    it "gruppi di progetti diversi → rifiutato prima della conferma" do
      other_project = create(:project, organization: org)
      a = create(:error_group, project:)
      b = create(:error_group, project: other_project)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ a.id, b.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
    end

    it "anti-BOLA: un gruppo di un'altra org fa fallire tutto, non viene silenziosamente scartato" do
      mine = create(:error_group, project:)
      other = create(:error_group)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ mine.id, other.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
    end

    it "chi ha solo il triage non arriva nemmeno alla conferma" do
      sign_in(triager)
      a = create(:error_group, project:)
      b = create(:error_group, project:)

      post merge_preview_member_monitoring_error_groups_path, params: { ids: [ a.id, b.id ] }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST merge — la fusione vera" do
    before { sign_in(owner) }

    it "sposta le occorrenze sul primario, somma i contatori e cancella gli assorbiti" do
      primary = create(:error_group, project:, events_count: 10)
      source  = create(:error_group, project:, events_count: 5)
      create(:error_event, group: source, project:)

      post merge_member_monitoring_error_groups_path,
           params: { confirm: "1", primary_id: primary.id, ids: [ primary.id, source.id ] }

      expect(response).to redirect_to(member_monitoring_error_group_path(primary))
      expect(flash[:notice]).to be_present
      expect(primary.reload.events_count).to eq(15)
      expect(primary.events.count).to eq(1)
      expect(Errors::Group.exists?(source.id)).to be(false)
    end

    it "il fingerprint assorbito resta puntato al primario (l'errore non ricompare)" do
      primary = create(:error_group, project:)
      source  = create(:error_group, project:, fingerprint: "assorbito")

      post merge_member_monitoring_error_groups_path,
           params: { confirm: "1", primary_id: primary.id, ids: [ source.id ] }

      expect(primary.reload.merged_fingerprints).to include("assorbito")
    end

    it "senza primario scelto non fonde niente" do
      a = create(:error_group, project:)
      b = create(:error_group, project:)

      post merge_member_monitoring_error_groups_path, params: { ids: [ a.id, b.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
      expect(Errors::Group.where(id: [ a.id, b.id ]).count).to eq(2)
    end

    # Il primario è l'unico gruppo scelto: non c'è niente da assorbire e il service lo direbbe.
    it "solo il primario selezionato → nessuna fusione, messaggio in chiaro" do
      primary = create(:error_group, project:)

      post merge_member_monitoring_error_groups_path,
           params: { confirm: "1", primary_id: primary.id, ids: [ primary.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
      expect(Errors::Group.exists?(primary.id)).to be(true)
    end

    it "anti-BOLA: primario di un'altra org → 404 e nessuna fusione" do
      other = create(:error_group)
      mine = create(:error_group, project:)

      post merge_member_monitoring_error_groups_path,
           params: { primary_id: other.id, ids: [ mine.id ] }

      expect(response).to have_http_status(:not_found)
      expect(Errors::Group.where(id: [ other.id, mine.id ]).count).to eq(2)
    end

    # Tutti o nessuno, come il service: fondere solo quelli riconosciuti lascerebbe l'operatore
    # convinto di aver unito tre gruppi mentre ne sono stati uniti due, senza modo di tornare indietro.
    it "una sorgente di un'altra org ferma tutta la fusione" do
      primary = create(:error_group, project:)
      mine = create(:error_group, project:)
      other = create(:error_group)

      post merge_member_monitoring_error_groups_path,
           params: { confirm: "1", primary_id: primary.id, ids: [ mine.id, other.id ] }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:alert]).to be_present
      expect(Errors::Group.exists?(mine.id)).to be(true)
    end

    it "chi ha solo il triage non fonde" do
      sign_in(triager)
      primary = create(:error_group, project:)
      source  = create(:error_group, project:)

      post merge_member_monitoring_error_groups_path,
           params: { primary_id: primary.id, ids: [ source.id ] }

      expect(response).to redirect_to(root_path)
      expect(Errors::Group.exists?(source.id)).to be(true)
    end
  end

  describe "senza sessione" do
    it "la fusione non è raggiungibile" do
      post merge_member_monitoring_error_groups_path, params: { ids: [] }
      expect(response).to redirect_to(login_path)
    end

    it "l'eliminazione non è raggiungibile" do
      group = create(:error_group, project:)

      delete member_monitoring_error_group_path(group)

      expect(response).to redirect_to(login_path)
      expect(Errors::Group.exists?(group.id)).to be(true)
    end
  end

  describe "PATCH resolve — la risoluzione documentata" do
    before { sign_in(owner) }

    it "scrive causa e rimedio sul gruppo" do
      group = create(:error_group, project:, status: :unresolved)

      patch resolve_member_monitoring_error_group_path(group),
            params: { cause: "Solid Cable su SQLite", fix: "Guard anti-ricorsione nell'SDK" }

      group.reload
      expect(group).to be_status_resolved
      expect(group.resolution_cause).to eq("Solid Cable su SQLite")
      expect(group.resolution_fix).to eq("Guard anti-ricorsione nell'SDK")
    end

    it "chiudere in fretta senza scrivere niente non cancella la spiegazione di prima" do
      group = create(:error_group, project:, status: :unresolved,
                     resolution_cause: "vecchia causa", resolution_fix: "vecchio rimedio")

      patch resolve_member_monitoring_error_group_path(group), params: { cause: "", fix: "" }

      expect(group.reload.resolution_cause).to eq("vecchia causa")
    end

    # Un gruppo riaperto non è più risolto: tenersi la spiegazione mentirebbe a chi lo ritrova.
    it "la riapertura azzera causa e rimedio" do
      group = create(:error_group, project:, status: :resolved,
                     resolution_cause: "c", resolution_fix: "f")

      patch reopen_member_monitoring_error_group_path(group)

      group.reload
      expect(group.resolution_cause).to be_nil
      expect(group.resolution_fix).to be_nil
    end

    it "la spiegazione si rilegge sulla pagina dell'errore" do
      group = create(:error_group, project:, status: :resolved,
                     resolution_cause: "Il lock di SQLite", resolution_fix: "Esclusione nell'SDK")

      get member_monitoring_error_group_path(group)

      # html_escape perché l'apostrofo esce come entità: cercare la stringa grezza non troverebbe
      # un testo che invece è in pagina, e il test sembrerebbe rosso per la ragione sbagliata.
      expect(response.body).to include(ERB::Util.html_escape("Il lock di SQLite"),
                                       ERB::Util.html_escape("Esclusione nell'SDK"))
    end

    # Un gruppo ancora aperto non ha una risoluzione da raccontare: il riquadro non deve comparire
    # con dentro la spiegazione di una chiusura precedente.
    it "il riquadro non compare su un errore non risolto" do
      group = create(:error_group, project:, status: :unresolved, resolution_cause: "vecchia")

      get member_monitoring_error_group_path(group)

      expect(response.body).not_to include("error-resolution\"")
    end

    it "l'elenco segnala quali risoluzioni sono spiegate" do
      create(:error_group, project:, status: :resolved, resolution_cause: "spiegata")

      get member_monitoring_error_groups_path(status: "resolved")

      expect(response.body).to include("error-resolution-noted")
    end
  end

  describe "DELETE destroy — l'eliminazione" do
    before { sign_in(owner) }

    it "elimina il gruppo e le sue occorrenze" do
      group = create(:error_group, project:)
      create(:error_event, group:, project:)

      delete member_monitoring_error_group_path(group), params: { confirm: "1" }

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:notice]).to be_present
      expect(Errors::Group.exists?(group.id)).to be(false)
      expect(Errors::Event.where(group_id: group.id).count).to eq(0)
    end

    it "chi ha solo il triage non elimina" do
      sign_in(triager)
      group = create(:error_group, project:)

      delete member_monitoring_error_group_path(group)

      expect(response).to redirect_to(root_path)
      expect(Errors::Group.exists?(group.id)).to be(true)
    end

    it "anti-BOLA: gruppo di un'altra org → 404" do
      group = create(:error_group)

      delete member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:not_found)
      expect(Errors::Group.exists?(group.id)).to be(true)
    end
  end
end
