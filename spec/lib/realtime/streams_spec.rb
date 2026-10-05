# frozen_string_literal: true

require "rails_helper"

# Registro dei nomi-stream Turbo. Si verifica che ogni helper produca la String attesa col
# prefisso tenant `org:<id>:`. Per gli helper org-diretti si usa un'organizzazione reale
# (record AR, costo minimo); per quelli derivati via progetto si usano doppi che esprimono il
# contratto di derivazione (record.project.organization_id) — la presenza del solo project_id
# (niente organization_id diretto) su quei modelli è verificata sullo schema.
RSpec.describe Realtime::Streams do
  describe "stream org-scoped (organizzazione passata direttamente)" do
    let(:organization) { create(:organization) }

    it "uptime" do
      expect(described_class.uptime(organization)).to eq("org:#{organization.id}:uptime")
    end

    it "logs" do
      expect(described_class.logs(organization)).to eq("org:#{organization.id}:logs")
    end

    it "errors" do
      expect(described_class.errors(organization)).to eq("org:#{organization.id}:errors")
    end

    it "metrics" do
      expect(described_class.metrics(organization)).to eq("org:#{organization.id}:metrics")
    end

    it "servers" do
      expect(described_class.servers(organization)).to eq("org:#{organization.id}:servers")
    end

    it "crons" do
      expect(described_class.crons(organization)).to eq("org:#{organization.id}:crons")
    end

    it "server_host usa l'organization_id diretto dell'host (risorsa org-scoped)" do
      host = instance_double("Servers::Host", id: "H-1", organization_id: "ORG-5")
      expect(described_class.server_host(host)).to eq("org:ORG-5:server_host:H-1")
    end

    it "cluster uses the direct organization_id of the cluster (CYAG-22)" do
      cluster = instance_double("Clusters::Cluster", id: "C-1", organization_id: "ORG-5")
      expect(described_class.cluster(cluster)).to eq("org:ORG-5:cluster:C-1")
    end

    it "presence_for è per-viewer (stream dedicato all'account)" do
      account = instance_double("Accounts::Account", id: "A-1")
      expect(described_class.presence_for(organization, account))
        .to eq("org:#{organization.id}:presence:account:A-1")
    end

    it "chat_conversation usa l'org denormalizzata della conversazione" do
      conversation = instance_double("Chat::Conversation", id: "C-1", organization_id: "ORG-9")
      expect(described_class.chat_conversation(conversation))
        .to eq("org:ORG-9:chat:conversation:C-1")
    end

    it "chat_inbox è account-scoped" do
      account = instance_double("Accounts::Account", id: "A-2")
      expect(described_class.chat_inbox(organization, account))
        .to eq("org:#{organization.id}:chat:inbox:A-2")
    end

    it "viewers usa to_gid_param della risorsa" do
      resource = instance_double("Ticketing::Ticket", to_gid_param: "Z2lkOi8vYXBwL1RpY2tldC8x")
      expect(described_class.viewers(organization, resource))
        .to eq("org:#{organization.id}:viewers:Z2lkOi8vYXBwL1RpY2tldC8x")
    end

    it "accetta anche un id grezzo come tenant (senza caricare il record)" do
      expect(described_class.servers("ORG-RAW")).to eq("org:ORG-RAW:servers")
    end
  end

  describe "board per progetto (CYRA-257)" do
    it "project_board è prefissata all'org del progetto e scopata al progetto" do
      org = create(:organization)
      project = create(:project, organization: org)

      expect(described_class.project_board(project))
        .to eq("org:#{org.id}:board:project:#{project.id}")
    end

    it "due progetti della stessa org hanno stream distinti (niente board org-wide)" do
      org = create(:organization)
      a = create(:project, organization: org)
      b = create(:project, organization: org)

      expect(described_class.project_board(a)).not_to eq(described_class.project_board(b))
    end
  end

  # CYRA-822 — l'aggiornamento della LISTA ha un secondo livello, per progetto: chi sta guardando un
  # solo progetto si iscrive lì e non riceve più il segnale org-wide che nasce dagli eventi di un
  # altro progetto. I nomi sono distinti da quelli org-wide E da quelli che portano HTML
  # (project_errors), che continuano a esistere per il replace della riga.
  describe "liste per progetto (CYRA-822)" do
    let(:org) { create(:organization) }
    let(:project) { create(:project, organization: org) }

    it "project_errors_list è prefissata all'org del progetto e scopata al progetto" do
      expect(described_class.project_errors_list(project))
        .to eq("org:#{org.id}:errors:list:project:#{project.id}")
    end

    it "project_metrics_list è prefissata all'org del progetto e scopata al progetto" do
      expect(described_class.project_metrics_list(project))
        .to eq("org:#{org.id}:metrics:list:project:#{project.id}")
    end

    it "project_logs_list è prefissata all'org del progetto e scopata al progetto" do
      expect(described_class.project_logs_list(project))
        .to eq("org:#{org.id}:logs:list:project:#{project.id}")
    end

    it "due progetti della stessa org hanno stream lista distinti" do
      altro = create(:project, organization: org)

      expect(described_class.project_errors_list(project))
        .not_to eq(described_class.project_errors_list(altro))
    end

    # Il nome che porta l'HTML della riga resta un altro: sovrapporli farebbe arrivare il replace
    # renderizzato anche a chi si è iscritto per il solo segnale di aggiornamento (CYRA-271).
    it "non coincide con lo stream che trasporta l'HTML della riga" do
      expect(described_class.project_errors_list(project))
        .not_to eq(described_class.project_errors(project))
    end

    it "non coincide con lo stream org-wide della stessa lista" do
      expect(described_class.project_errors_list(project)).not_to eq(described_class.errors(org))
      expect(described_class.project_metrics_list(project)).not_to eq(described_class.metrics(org))
      expect(described_class.project_logs_list(project)).not_to eq(described_class.logs(org))
    end

    # Un nome di lista per progetto non deve poter essere prodotto anche da un altro helper: due
    # helper che collidono consegnerebbero l'uno il traffico dell'altro.
    it "i tre nomi sono distinti fra loro" do
      nomi = [ described_class.project_errors_list(project), described_class.project_metrics_list(project),
               described_class.project_logs_list(project) ]

      expect(nomi.uniq.size).to eq(3)
    end
  end

  describe "stream derivati dall'org via progetto" do
    let(:project) { instance_double("Projects::Project", organization_id: "ORG-7") }

    it "ticket -> org del progetto + id ticket" do
      ticket = instance_double("Ticketing::Ticket", id: "T-1", project: project)
      expect(described_class.ticket(ticket)).to eq("org:ORG-7:ticket:T-1")
    end

    it "monitor -> org del progetto + id monitor" do
      monitor = instance_double("Uptime::Monitor", id: "M-1", project: project)
      expect(described_class.monitor(monitor)).to eq("org:ORG-7:monitor:M-1")
    end

    it "error_group -> org del progetto + id gruppo" do
      group = instance_double("Errors::Group", id: "EG-1", project: project)
      expect(described_class.error_group(group)).to eq("org:ORG-7:error_group:EG-1")
    end

    it "metric_group -> org del progetto + id gruppo" do
      group = instance_double("Metrics::Group", id: "MG-1", project: project)
      expect(described_class.metric_group(group)).to eq("org:ORG-7:metric_group:MG-1")
    end

    it "cron_monitor -> org del progetto + id monitor" do
      monitor = instance_double("Crons::Monitor", id: "CM-1", project: project)
      expect(described_class.cron_monitor(monitor)).to eq("org:ORG-7:cron_monitor:CM-1")
    end

    it "analytics -> org del progetto + id progetto (dashboard per-progetto)" do
      dashboard_project = instance_double("Projects::Project", id: "P-1", organization_id: "ORG-7")
      expect(described_class.analytics(dashboard_project)).to eq("org:ORG-7:analytics:project:P-1")
    end
  end

  describe "isolamento tenant" do
    it "due organizzazioni distinte producono prefissi distinti sullo stesso tipo di stream" do
      org_a = create(:organization)
      org_b = create(:organization)

      expect(described_class.uptime(org_a)).to start_with("org:#{org_a.id}:")
      expect(described_class.uptime(org_b)).to start_with("org:#{org_b.id}:")
      expect(described_class.uptime(org_a)).not_to eq(described_class.uptime(org_b))
    end

    it "ogni helper restituisce una String tenant-prefissata" do
      org = create(:organization)
      account = instance_double("Accounts::Account", id: "A")
      project = instance_double("Projects::Project", id: "P", organization_id: org.id)
      ticket = instance_double("Ticketing::Ticket", id: "T", project: project)
      resource = instance_double("Ticketing::Ticket", to_gid_param: "GID")

      streams = [
        described_class.project_board(project), described_class.ticket(ticket),
        described_class.uptime(org), described_class.logs(org),
        described_class.errors(org), described_class.metrics(org),
        described_class.presence_for(org, account), described_class.viewers(org, resource)
      ]

      streams.each do |stream|
        expect(stream).to be_a(String)
        expect(stream).to start_with("org:#{org.id}:")
      end
    end
  end
end
