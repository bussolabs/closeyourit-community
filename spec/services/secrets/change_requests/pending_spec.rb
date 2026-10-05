# frozen_string_literal: true

require "rails_helper"

# Report "Richieste in attesa" (CYRA-138, Fase 4 pezzo C2b — UI): raccoglie le Secrets::ChangeRequest
# pending dei progetti VISIBILI passati, filtrate ANTI-DISCLOSURE — una CR espone il nome del secret
# nel campo `name`, quindi un account che vede il progetto ma non può gestirne i secret NON deve
# scoprire che una modifica è in revisione, a meno che sia stato lui a proporla.
RSpec.describe Secrets::ChangeRequests::Pending do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:manager) { create(:account) } # secrets.manage sul progetto
  let(:requester) { create(:account) } # NON gestisce il progetto, ha solo proposto la CR

  def grant_manage(account, on: project)
    # project_membership crea la Connections::Membership mancante nel suo after(:build) → va chiamato PRIMA
    # (AccountPermission valida che l'account sia membro dell'org).
    create(:project_membership, account:, project: on)
    # Override creato DIRETTAMENTE: questo spec testa Pending, non la concessione dei permessi. Passare da
    # SetAccountPermissions con un attore non-owner ora è bloccato dal subset-check (CYRA-156: secrets.manage
    # è una chiave scoped) → il setup lo scavalca creando l'AccountPermission a mano.
    # find_or_create: l'override è org-wide (una riga per [account, org, chiave]); chiamando grant_manage
    # due volte per lo stesso account (es. su un secondo progetto) non va duplicato.
    account.account_permissions.find_or_create_by!(organization: on.organization, permission_key: "secrets.manage") do |ap|
      ap.effect = "allow"
    end
  end

  def pending_request(**attrs)
    create(:secret_change_request, project:, organization: org, environment:, requested_by: requester, **attrs)
  end

  before { grant_manage(manager) }

  describe "#requests" do
    it "elenca le CR pending dei progetti visibili" do
      change_request = pending_request(name: "API_KEY")

      report = described_class.new(account: manager, projects: [ project ])

      expect(report.requests).to contain_exactly(change_request)
    end

    it "esclude le CR non più pending (applied/rejected/cancelled)" do
      applied = pending_request(name: "APPLIED")
      applied.update!(status: :applied, decided_by: manager, decided_at: Time.current)
      rejected = pending_request(name: "REJECTED")
      rejected.update!(status: :rejected, decided_by: manager, decided_at: Time.current, reason: "no")
      cancelled = pending_request(name: "CANCELLED")
      cancelled.update!(status: :cancelled, decided_by: requester, decided_at: Time.current)

      report = described_class.new(account: manager, projects: [ project ])

      expect(report.requests).to be_empty
    end

    it "scoping: una CR di un progetto NON incluso tra i projects passati non compare" do
      other_project = create(:project, organization: org)
      other_environment = create(:environment, organization: org).tap { |e| other_project.environments << e }
      grant_manage(manager, on: other_project)
      create(:secret_change_request, project: other_project, organization: org, environment: other_environment,
             requested_by: requester, name: "OTHER")

      report = described_class.new(account: manager, projects: [ project ])

      expect(report.requests).to be_empty
    end

    it "ordina le richieste dalla più vecchia (in attesa da più tempo) alla più recente" do
      older = pending_request(name: "OLDER")
      older.update_column(:created_at, 2.days.ago)
      newer = pending_request(name: "NEWER")
      newer.update_column(:created_at, 1.hour.ago)

      report = described_class.new(account: manager, projects: [ project ])

      expect(report.requests).to eq([ older, newer ])
    end

    describe "anti-disclosure" do
      it "un account senza secrets.manage e NON richiedente non vede la CR del progetto" do
        pending_request(name: "SECRET_NAME")
        outsider = create(:account)
        create(:project_membership, account: outsider, project:) # vede il progetto, non lo gestisce

        report = described_class.new(account: outsider, projects: [ project ])

        expect(report.requests).to be_empty
      end

      it "il richiedente vede la PROPRIA CR anche senza secrets.manage sul progetto" do
        change_request = pending_request(name: "SECRET_NAME")

        report = described_class.new(account: requester, projects: [ project ])

        expect(report.requests).to contain_exactly(change_request)
      end

      it "il richiedente NON vede la CR di un ALTRO richiedente sullo stesso progetto se non gestisce" do
        pending_request(name: "OTHERS_REQUEST")
        other_requester = create(:account)
        create(:project_membership, account: other_requester, project:)

        report = described_class.new(account: other_requester, projects: [ project ])

        expect(report.requests).to be_empty
      end

      it "chi gestisce il progetto vede ANCHE le CR altrui (non solo le proprie)" do
        change_request = pending_request(name: "SECRET_NAME")

        report = described_class.new(account: manager, projects: [ project ])

        expect(report.requests).to contain_exactly(change_request)
      end
    end
  end

  describe "#count / #decidable_count / #mine_count" do
    it "conta il totale visibile, quelle decidibili e le proprie" do
      pending_request(name: "MINE") # visibile al manager perché lui gestisce, e al requester perché sua
      grant_manage(other_manager = create(:account))
      pending_request(name: "OTHERS", requested_by: other_manager)

      report = described_class.new(account: manager, projects: [ project ])

      expect(report.count).to eq(2)
      expect(report.decidable_count).to eq(2) # manager non ha chiesto nessuna delle due
      expect(report.mine_count).to eq(0)
    end

    it "per il richiedente: la propria è 'mine', non è mai decidibile da sé stesso" do
      pending_request(name: "MINE")

      report = described_class.new(account: requester, projects: [ project ])

      expect(report.count).to eq(1)
      expect(report.decidable_count).to eq(0)
      expect(report.mine_count).to eq(1)
    end
  end

  describe "#any?" do
    it "false senza CR pending" do
      report = described_class.new(account: manager, projects: [ project ])
      expect(report.any?).to be(false)
    end

    it "true con almeno una CR pending visibile" do
      pending_request(name: "API_KEY")
      report = described_class.new(account: manager, projects: [ project ])
      expect(report.any?).to be(true)
    end

    it "false su una lista di progetti vuota" do
      expect(described_class.new(account: manager, projects: []).any?).to be(false)
    end
  end

  describe "#can_decide?" do
    it "vero per chi gestisce il progetto e NON è il richiedente" do
      change_request = pending_request(name: "API_KEY")
      report = described_class.new(account: manager, projects: [ project ])

      expect(report.can_decide?(change_request)).to be(true)
    end

    it "falso per il richiedente stesso (vincolo 4-eyes)" do
      change_request = pending_request(name: "API_KEY")
      report = described_class.new(account: requester, projects: [ project ])

      expect(report.can_decide?(change_request)).to be(false)
    end
  end

  describe "#can_cancel?" do
    it "vero solo per il richiedente" do
      change_request = pending_request(name: "API_KEY")
      report = described_class.new(account: requester, projects: [ project ])

      expect(report.can_cancel?(change_request)).to be(true)
    end

    it "falso per chi gestisce ma non ha richiesto" do
      change_request = pending_request(name: "API_KEY")
      report = described_class.new(account: manager, projects: [ project ])

      expect(report.can_cancel?(change_request)).to be(false)
    end
  end
end
