require "rails_helper"

RSpec.describe Projects::Project, type: :model do
  describe "factory" do
    it "produce un progetto valido" do
      expect(build(:project)).to be_valid
    end
  end

  describe "validazioni name" do
    it "richiede name" do
      expect(build(:project, name: nil)).not_to be_valid
    end

    it "rifiuta name di soli spazi" do
      expect(build(:project, name: "   ")).not_to be_valid
    end
  end

  describe "validazioni key" do
    it "richiede key" do
      expect(build(:project, key: nil)).not_to be_valid
    end

    it "normalizza la key in maiuscolo e trimma" do
      project = create(:project, key: "  str  ")
      expect(project.key).to eq("STR")
    end

    it "accetta lettere e cifre" do
      expect(build(:project, key: "STR2")).to be_valid
    end

    it "rifiuta caratteri non ammessi" do
      expect(build(:project, key: "ST-1")).not_to be_valid
    end

    it "accetta una key di 4 caratteri (limite massimo)" do
      expect(build(:project, key: "ABCD")).to be_valid
    end

    it "rifiuta una key più lunga di 4 caratteri" do
      expect(build(:project, key: "ABCDE")).not_to be_valid
    end

    it "rifiuta key duplicata nella stessa organizzazione" do
      org = create(:organization)
      create(:project, organization: org, key: "STR")
      expect(build(:project, organization: org, key: "STR")).not_to be_valid
    end

    it "permette la stessa key in organizzazioni diverse" do
      create(:project, organization: create(:organization), key: "STR")
      expect(build(:project, organization: create(:organization), key: "STR")).to be_valid
    end
  end

  describe "descrizione (opzionale)" do
    it "è valida senza descrizione" do
      expect(build(:project, description: nil)).to be_valid
    end

    it "normalizza (strip) la descrizione quando presente" do
      project = create(:project, description: "  Public storefront  ")
      expect(project.description).to eq("Public storefront")
    end
  end

  describe "associazioni" do
    it "appartiene a un'organizzazione" do
      org = create(:organization)
      expect(create(:project, organization: org).organization).to eq(org)
    end

    it "richiede un'organizzazione" do
      expect(build(:project, organization: nil)).not_to be_valid
    end

    it "ha created_by opzionale" do
      expect(build(:project, created_by: nil)).to be_valid
    end

    it "può riferire l'account creatore" do
      account = create(:account)
      expect(create(:project, created_by: account).created_by).to eq(account)
    end
  end

  describe "gruppo (integrità tenant)" do
    it "accetta un gruppo della stessa organizzazione" do
      org = create(:organization)
      group = create(:group, organization: org)
      expect(build(:project, organization: org, group: group)).to be_valid
    end

    it "rifiuta un gruppo di un'altra organizzazione" do
      org = create(:organization)
      foreign_group = create(:group, organization: create(:organization))
      project = build(:project, organization: org, group: foreign_group)
      expect(project).not_to be_valid
      expect(project.errors[:group]).to be_present
    end

    it "è valido senza gruppo (opzionale)" do
      expect(build(:project, group: nil)).to be_valid
    end
  end

  describe "retention log per-progetto (store_accessor su preferences)" do
    it "è nil di default (eredita dal livello superiore)" do
      expect(build(:project).logs_retention_days).to be_nil
    end

    it "normalizza un valore stringa a Integer" do
      project = create(:project, logs_retention_days: "30")
      expect(project.reload.logs_retention_days).to eq(30)
    end

    it "normalizza un valore blank a nil (eredita)" do
      expect(create(:project, logs_retention_days: "").logs_retention_days).to be_nil
    end

    it "accetta i confini 1 e 365" do
      expect(build(:project, logs_retention_days: 1)).to be_valid
      expect(build(:project, logs_retention_days: 365)).to be_valid
    end

    it "rifiuta valori fuori da 1..365" do
      expect(build(:project, logs_retention_days: 0)).not_to be_valid
      expect(build(:project, logs_retention_days: 366)).not_to be_valid
    end
  end

  describe "retention errori/performance/uptime per-progetto (CYRA-159, store_accessor su preferences)" do
    it "sono nil di default (ereditano dal livello superiore)" do
      project = build(:project)
      expect(project.errors_retention_days).to be_nil
      expect(project.performance_retention_days).to be_nil
      expect(project.uptime_retention_days).to be_nil
    end

    it "normalizzano un valore stringa a Integer" do
      project = create(:project, errors_retention_days: "90", performance_retention_days: "60", uptime_retention_days: "365")
      project.reload
      expect(project.errors_retention_days).to eq(90)
      expect(project.performance_retention_days).to eq(60)
      expect(project.uptime_retention_days).to eq(365)
    end

    it "normalizzano un valore blank a nil (eredita)" do
      project = create(:project, errors_retention_days: "")
      expect(project.errors_retention_days).to be_nil
    end

    it "accettano i confini 1..365 per errori/performance" do
      expect(build(:project, errors_retention_days: 1)).to be_valid
      expect(build(:project, errors_retention_days: 365)).to be_valid
      expect(build(:project, performance_retention_days: 1)).to be_valid
      expect(build(:project, performance_retention_days: 365)).to be_valid
    end

    it "rifiutano errori/performance fuori da 1..365" do
      expect(build(:project, errors_retention_days: 0)).not_to be_valid
      expect(build(:project, errors_retention_days: 366)).not_to be_valid
      expect(build(:project, performance_retention_days: 0)).not_to be_valid
      expect(build(:project, performance_retention_days: 366)).not_to be_valid
    end

    it "accetta i confini 1..730 per uptime" do
      expect(build(:project, uptime_retention_days: 1)).to be_valid
      expect(build(:project, uptime_retention_days: 730)).to be_valid
    end

    it "rifiuta uptime fuori da 1..730" do
      expect(build(:project, uptime_retention_days: 0)).not_to be_valid
      expect(build(:project, uptime_retention_days: 731)).not_to be_valid
    end
  end

  describe "origin allowlist per-progetto (public ingest, CYRA-109)" do
    it "è una lista vuota di default (nessun vincolo di provenienza)" do
      project = build(:project)
      expect(project.allowed_origins).to eq([])
      expect(project.origin_allowlist?).to be(false)
    end

    it "normalizza una stringa multi-riga in una lista di origini pulite (downcase, no slash finale)" do
      project = create(:project, allowed_origins: "https://App.Example.com/\n http://localhost:3000 ")
      expect(project.reload.allowed_origins).to eq(%w[https://app.example.com http://localhost:3000])
    end

    it "accetta un array, scarta i vuoti e deduplica" do
      project = create(:project, allowed_origins: [ "https://a.example", "", "https://a.example", "https://b.example" ])
      expect(project.reload.allowed_origins).to eq(%w[https://a.example https://b.example])
    end

    it "separa anche su virgole" do
      project = create(:project, allowed_origins: "https://a.example, https://b.example")
      expect(project.reload.allowed_origins).to eq(%w[https://a.example https://b.example])
    end

    it "rifiuta origini malformate (con path, senza schema, o con spazi interni)" do
      expect(build(:project, allowed_origins: [ "https://ok.example/path" ])).not_to be_valid
      expect(build(:project, allowed_origins: [ "ok.example" ])).not_to be_valid
      expect(build(:project, allowed_origins: [ "ftp://ok.example" ])).not_to be_valid
    end

    it "accetta host con porta e sottodomini" do
      expect(build(:project, allowed_origins: %w[https://app.acme.example:8443 http://sub.localhost])).to be_valid
    end

    describe "#origin_allowed? (0/1/N origini)" do
      it "0 origini: qualsiasi origine è consentita (allowlist non configurata)" do
        project = build(:project, allowed_origins: [])
        expect(project.origin_allowed?("https://qualsiasi.example")).to be(true)
      end

      it "1 origine: solo quella è consentita, il confronto è case-insensitive" do
        project = build(:project, allowed_origins: [ "https://app.example" ])
        expect(project.origin_allowed?("https://app.example")).to be(true)
        expect(project.origin_allowed?("https://APP.example")).to be(true)
        expect(project.origin_allowed?("https://altro.example")).to be(false)
      end

      it "N origini: ciascuna elencata è consentita, le altre no" do
        project = build(:project, allowed_origins: %w[https://a.example https://b.example])
        expect(project.origin_allowed?("https://a.example")).to be(true)
        expect(project.origin_allowed?("https://b.example")).to be(true)
        expect(project.origin_allowed?("https://c.example")).to be(false)
      end

      it "un'origine assente (nil) con allowlist attiva NON è consentita" do
        project = build(:project, allowed_origins: [ "https://app.example" ])
        expect(project.origin_allowed?(nil)).to be(false)
      end
    end
  end

  describe "#supports_uptime? e scope .uptime_capable (capability piattaforma)" do
    let(:org) { create(:organization) }

    it "false senza piattaforme dichiarate (strict: niente uptime finché non c'è una web)" do
      expect(create(:project, organization: org).supports_uptime?).to be(false)
    end

    it "false con sole piattaforme native (ios/android)" do
      project = create(:project, organization: org)
      project.platforms << create(:platform, organization: org) # supports_uptime false
      expect(project.supports_uptime?).to be(false)
    end

    it "true se almeno una piattaforma è uptime-capable (web/server)" do
      project = create(:project, organization: org)
      project.platforms << create(:platform, organization: org)                  # nativa
      project.platforms << create(:platform, :uptime_capable, organization: org) # web
      expect(project.supports_uptime?).to be(true)
    end

    it ".uptime_capable include solo i progetti con ≥1 piattaforma uptime-capable" do
      web_project = create(:project, organization: org)
      web_project.platforms << create(:platform, :uptime_capable, organization: org)
      native_project = create(:project, organization: org)
      native_project.platforms << create(:platform, organization: org)
      no_platform = create(:project, organization: org)

      expect(described_class.uptime_capable).to contain_exactly(web_project)
      expect(described_class.uptime_capable).not_to include(native_project, no_platform)
    end
  end

  describe "quick_bug_report_enabled (modalità rapida del form bug)" do
    it "è false di default" do
      expect(create(:project).quick_bug_report_enabled?).to be(false)
    end

    it "è persistibile a true" do
      expect(create(:project, quick_bug_report_enabled: true).reload.quick_bug_report_enabled?).to be(true)
    end
  end

  describe "#performance_alert_threshold (soglia, default se blank)" do
    it "valore presente → salvato come Integer e ritornato dal getter" do
      project = build(:project)
      project.performance_alert_threshold = "42"
      expect(project.performance_alert_threshold).to eq(42)
    end

    it "valore blank → azzerato dal setter, il getter ricade sul default" do
      project = build(:project, performance_alert_threshold: 7)
      project.performance_alert_threshold = ""
      expect(project.read_attribute(:performance_alert_threshold)).to be_nil
      expect(project.performance_alert_threshold).to eq(Metrics::Constants::ALERT_THRESHOLD_DEFAULT)
    end
  end

  describe "default_assignee (assegnatario di default dei ticket)" do
    it "è valido senza default_assignee (colonna nullable)" do
      expect(build(:project, default_assignee: nil)).to be_valid
    end

    it "accetta un default_assignee membro dell'organizzazione" do
      org = create(:organization)
      member = create(:account)
      create(:membership, account: member, organization: org)
      project = build(:project, organization: org, default_assignee: member)
      expect(project).to be_valid
    end

    it "rifiuta un default_assignee non membro dell'organizzazione (anti-BOLA)" do
      org = create(:organization)
      outsider = create(:account)
      project = build(:project, organization: org, default_assignee: outsider)
      expect(project).not_to be_valid
      expect(project.errors[:default_assignee]).to be_present
    end
  end

  # A project inside a group that has a color wears the group's color.
  describe "group color" do
    let(:organization) { create(:organization) }
    let(:group) { create(:group, organization:, color: "emerald") }

    it "takes the color of its group when created" do
      project = create(:project, organization:, group:, color: "violet")

      expect(project.color).to eq("emerald")
    end

    it "takes the color of the group it is moved into" do
      project = create(:project, organization:, color: "violet")

      project.update!(group:)

      expect(project.color).to eq("emerald")
    end

    it "refuses another color while it stays in the group" do
      project = create(:project, organization:, group:)

      project.update!(color: "rose")

      expect(project.reload.color).to eq("emerald")
    end

    it "keeps its own color in a group without one, and after leaving a group" do
      plain = create(:group, organization:, color: nil)
      project = create(:project, organization:, group: plain, color: "violet")
      expect(project.color).to eq("violet")

      colored = create(:project, organization:, group:)
      colored.update!(group: nil)
      expect(colored.color).to eq("emerald")
      colored.update!(color: "rose")
      expect(colored.reload.color).to eq("rose")
    end
  end
end
