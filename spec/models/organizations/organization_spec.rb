require "rails_helper"

RSpec.describe Organizations::Organization, type: :model do
  describe "factory" do
    it "produce un'organizzazione valida" do
      expect(build(:organization)).to be_valid
    end
  end

  describe "validazioni name" do
    it "richiede name" do
      expect(build(:organization, name: nil)).not_to be_valid
    end

    it "rifiuta name di soli spazi" do
      expect(build(:organization, name: "   ")).not_to be_valid
    end
  end

  describe "validazioni slug" do
    it "richiede slug" do
      expect(build(:organization, slug: nil)).not_to be_valid
    end

    it "rifiuta slug duplicato" do
      create(:organization, slug: "acme")
      expect(build(:organization, slug: "acme")).not_to be_valid
    end

    it "rifiuta slug duplicato case-insensitive (normalize downcase)" do
      create(:organization, slug: "Acme")
      expect(build(:organization, slug: "acme")).not_to be_valid
    end

    it "rifiuta slug con caratteri non ammessi" do
      expect(build(:organization, slug: "Acme Spa!")).not_to be_valid
    end

    it "accetta slug con lettere, cifre e trattini" do
      expect(build(:organization, slug: "acme-2")).to be_valid
    end
  end

  describe "normalizzazioni" do
    it "abbassa e trimma lo slug" do
      org = create(:organization, slug: "  Acme  ")
      expect(org.slug).to eq("acme")
    end

    it "trimma il name" do
      org = create(:organization, name: "  Acme  ")
      expect(org.name).to eq("Acme")
    end
  end

  describe "created_by (fondatore opzionale)" do
    it "è valida senza created_by" do
      expect(build(:organization, created_by: nil)).to be_valid
    end

    it "può riferire un account fondatore" do
      account = create(:account)
      org = create(:organization, created_by: account)
      expect(org.created_by).to eq(account)
    end
  end

  describe "owner (helper via membership)" do
    let(:org) { create(:organization) }

    it "è nil senza membership owner" do
      expect(org.owner).to be_nil
    end

    it "restituisce l'account della membership con ruolo owner" do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :owner)
      expect(org.owner).to eq(account)
    end

    it "ignora i membri non owner" do
      create(:membership, account: create(:account), organization: org, role: :admin)
      expect(org.owner).to be_nil
    end
  end

  describe "associazioni con gli account" do
    let(:org) { create(:organization) }

    it "nessun account di default (0)" do
      expect(org.accounts).to be_empty
    end

    it "un account via membership (1)" do
      account = create(:account)
      create(:membership, account: account, organization: org)
      expect(org.accounts).to contain_exactly(account)
    end

    it "più account via membership (N)" do
      accounts = create_list(:account, 3)
      accounts.each { |a| create(:membership, account: a, organization: org) }
      expect(org.accounts).to match_array(accounts)
    end

    it "distrugge le membership quando l'organizzazione è eliminata" do
      create(:membership, organization: org, account: create(:account))
      expect { org.destroy }.to change(Connections::Membership, :count).by(-1)
    end
  end

  describe "associazioni con i progetti" do
    let(:org) { create(:organization) }

    it "nessun progetto di default (0)" do
      expect(org.projects).to be_empty
    end

    it "uno o più progetti (1/N)" do
      projects = create_list(:project, 2, organization: org)
      expect(org.projects).to match_array(projects)
    end

    it "distrugge i progetti quando l'organizzazione è eliminata" do
      create(:project, organization: org)
      expect { org.destroy }.to change(Projects::Project, :count).by(-1)
    end
  end

  describe "preferenza default_projects_view (store_accessor su preferences jsonb)" do
    it "è nil di default" do
      expect(build(:organization).default_projects_view).to be_nil
    end

    it "accetta 'cards'" do
      expect(build(:organization, default_projects_view: "cards")).to be_valid
    end

    it "accetta 'table'" do
      expect(build(:organization, default_projects_view: "table")).to be_valid
    end

    it "accetta nil (nessun default)" do
      expect(build(:organization, default_projects_view: nil)).to be_valid
    end

    it "rifiuta un valore fuori dall'insieme ammesso" do
      org = build(:organization, default_projects_view: "kanban")
      expect(org).not_to be_valid
      expect(org.errors[:default_projects_view]).to be_present
    end

    it "persiste la scelta nella colonna jsonb" do
      org = create(:organization, default_projects_view: "table")
      expect(org.reload.default_projects_view).to eq("table")
    end
  end

  describe "retention log di default org (store_accessor su preferences)" do
    it "è nil di default (eredita dal god)" do
      expect(build(:organization).logs_retention_days).to be_nil
    end

    it "normalizza un valore stringa a Integer" do
      org = create(:organization, logs_retention_days: "30")
      expect(org.reload.logs_retention_days).to eq(30)
    end

    it "normalizza un valore blank a nil (eredita)" do
      expect(create(:organization, logs_retention_days: "").logs_retention_days).to be_nil
    end

    it "accetta i confini 1 e 365" do
      expect(build(:organization, logs_retention_days: 1)).to be_valid
      expect(build(:organization, logs_retention_days: 365)).to be_valid
    end

    it "rifiuta valori fuori da 1..365" do
      expect(build(:organization, logs_retention_days: 0)).not_to be_valid
      expect(build(:organization, logs_retention_days: 366)).not_to be_valid
    end
  end

  describe "retention errori/performance/server/uptime di default org (CYRA-159, store_accessor su preferences)" do
    it "sono nil di default (ereditano dal god)" do
      org = build(:organization)
      expect(org.errors_retention_days).to be_nil
      expect(org.performance_retention_days).to be_nil
      expect(org.servers_retention_days).to be_nil
      expect(org.uptime_retention_days).to be_nil
    end

    it "normalizzano un valore stringa a Integer" do
      org = create(:organization, errors_retention_days: "90", performance_retention_days: "60",
                                  servers_retention_days: "15", uptime_retention_days: "365")
      org.reload
      expect(org.errors_retention_days).to eq(90)
      expect(org.performance_retention_days).to eq(60)
      expect(org.servers_retention_days).to eq(15)
      expect(org.uptime_retention_days).to eq(365)
    end

    it "normalizzano un valore blank a nil (eredita)" do
      expect(create(:organization, servers_retention_days: "").servers_retention_days).to be_nil
    end

    it "accettano i confini 1..365 per errori/performance/server" do
      expect(build(:organization, errors_retention_days: 1)).to be_valid
      expect(build(:organization, errors_retention_days: 365)).to be_valid
      expect(build(:organization, performance_retention_days: 1)).to be_valid
      expect(build(:organization, performance_retention_days: 365)).to be_valid
      expect(build(:organization, servers_retention_days: 1)).to be_valid
      expect(build(:organization, servers_retention_days: 365)).to be_valid
    end

    it "rifiutano errori/performance/server fuori da 1..365" do
      expect(build(:organization, errors_retention_days: 0)).not_to be_valid
      expect(build(:organization, errors_retention_days: 366)).not_to be_valid
      expect(build(:organization, performance_retention_days: 0)).not_to be_valid
      expect(build(:organization, performance_retention_days: 366)).not_to be_valid
      expect(build(:organization, servers_retention_days: 0)).not_to be_valid
      expect(build(:organization, servers_retention_days: 366)).not_to be_valid
    end

    it "accetta i confini 1..730 per uptime" do
      expect(build(:organization, uptime_retention_days: 1)).to be_valid
      expect(build(:organization, uptime_retention_days: 730)).to be_valid
    end

    it "rifiuta uptime fuori da 1..730" do
      expect(build(:organization, uptime_retention_days: 0)).not_to be_valid
      expect(build(:organization, uptime_retention_days: 731)).not_to be_valid
    end
  end

  describe "default_assignee (assegnatario di default dei ticket)" do
    it "è valida senza default_assignee (colonna nullable)" do
      expect(build(:organization, default_assignee: nil)).to be_valid
    end

    it "accetta un default_assignee membro dell'organizzazione" do
      org = create(:organization)
      member = create(:account)
      create(:membership, account: member, organization: org)
      org.default_assignee = member
      expect(org).to be_valid
    end

    it "rifiuta un default_assignee non membro dell'organizzazione (anti-BOLA)" do
      org = create(:organization)
      outsider = create(:account)
      org.default_assignee = outsider
      expect(org).not_to be_valid
      expect(org.errors[:default_assignee]).to be_present
    end
  end
end
