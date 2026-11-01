# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::SetSecretAccess do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:membership) { create(:membership, account:, organization:, role: :member) }
  let(:project) { create(:project, organization:) }

  before do
    %w[development staging production].each { |code| create(:environment, organization:, code:) }
  end

  def per_project_codes(target = project)
    Connections::AccountSecretAccess.find_by(account:, project: target)&.environment_codes
  end

  describe "allow-list org-wide" do
    it "salva solo i code che esistono davvero nell'organizzazione (anti-lockout)" do
      result = described_class.call(membership:, org_wide_codes: [ "staging", "inesistente" ], per_project: {})

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "una lista vuota toglie la restrizione" do
      membership.update!(secret_environment_codes: [ "staging" ])

      described_class.call(membership:, org_wide_codes: [], per_project: {})

      expect(membership.reload.secret_environment_codes).to eq([])
    end

    it "normalizza spazi e maiuscole prima di confrontare" do
      described_class.call(membership:, org_wide_codes: [ " Staging " ], per_project: {})

      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end
  end

  describe "override per-progetto" do
    it "crea la riga di override coi soli code reali dell'organizzazione" do
      described_class.call(membership:, org_wide_codes: [ "staging" ],
                           per_project: { project.id => [ "staging", "production", "inesistente" ] })

      expect(per_project_codes).to eq(%w[staging production])
    end

    it "aggiorna un override esistente" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [ "development" ] })

      expect(per_project_codes).to eq([ "development" ])
    end

    it "una lista vuota rimuove l'override invece di salvarlo vuoto" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [] })

      expect(Connections::AccountSecretAccess.where(account:, project:)).not_to exist
    end

    it "un progetto NON toccato dai parametri resta com'è" do
      other = create(:project, organization:)
      create(:account_secret_access, account:, project: other, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [ "staging" ] })

      expect(per_project_codes(other)).to eq([ "production" ])
    end

    it "ignora un progetto di un'altra organizzazione (anti-BOLA)" do
      foreign = create(:project)

      result = described_class.call(membership:, org_wide_codes: [], per_project: { foreign.id => [ "staging" ] })

      expect(result).to be_ok
      expect(Connections::AccountSecretAccess.where(project: foreign)).not_to exist
    end

    it "ignora un id di progetto inesistente" do
      result = described_class.call(membership:, org_wide_codes: [], per_project: { SecureRandom.uuid => [ "staging" ] })

      expect(result).to be_ok
      expect(Connections::AccountSecretAccess.count).to eq(0)
    end
  end

  it "accetta i parametri così come arrivano dal form (chiavi stringa, valori array)" do
    described_class.call(membership:, org_wide_codes: [ "", "staging" ],
                         per_project: { project.id.to_s => [ "", "production" ] })

    expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    expect(per_project_codes).to eq([ "production" ])
  end

  # CYRA-1118 — una lista vuota vale "tutti gli ambienti": una lista di soli refusi non deve diventarlo.
  describe "lista di soli ambienti inesistenti" do
    it "org-wide: rifiutata, il confine resta com'era" do
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [ "inesistente", "" ], per_project: {})

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-008")
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "per progetto: rifiutata, l'override resta com'era" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [ "inesistente" ] })

      expect(result.error.code).to eq("R422-SECRET-008")
      expect(per_project_codes).to eq([ "staging" ])
    end

    it "vale anche per il proprietario" do
      owner = create(:account)
      create(:membership, account: owner, organization:, role: :owner)

      result = described_class.call(membership:, org_wide_codes: [ "inesistente" ], actor: owner)

      expect(result.error.code).to eq("R422-SECRET-008")
    end
  end

  # CYRA-1118 — chi modifica non può aprire ambienti che non vede (gemello di ScopeGuard sui progetti).
  describe "guard anti-allargamento (actor)" do
    let(:actor) do
      create(:account).tap do |manager|
        create(:membership, account: manager, organization:, role: :member, secret_environment_codes: [ "staging" ])
      end
    end
    let(:actor_membership) { Connections::Membership.find_by(account: actor, organization:) }

    it "svuotare la propria lista è rifiutato" do
      result = described_class.call(membership: actor_membership, org_wide_codes: [], actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.details[:forbidden_environment_codes]).to eq(%w[development production])
      expect(actor_membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "aggiungere la produzione ai propri ambienti è rifiutato" do
      result = described_class.call(membership: actor_membership, org_wide_codes: %w[staging production], actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(actor_membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "dare a un collega un ambiente che l'attore non vede è rifiutato" do
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: %w[staging production], actor:)

      expect(result).to be_err
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "svuotare la lista di un collega limitato è rifiutato" do
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [], actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "restringere un collega senza limiti è permesso" do
      result = described_class.call(membership:, org_wide_codes: [ "staging" ], actor:)

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "riconfermare ambienti che il collega aveva già è permesso" do
      membership.update!(secret_environment_codes: %w[staging production])

      result = described_class.call(membership:, org_wide_codes: [ "production" ], actor:)

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([ "production" ])
    end

    it "dare la produzione su un solo progetto è rifiutato, il progetto resta com'era" do
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [ "staging" ],
                                    per_project: { project.id => [ "production" ] }, actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.details[:project_id]).to eq(project.id)
      expect(per_project_codes).to be_nil
    end

    it "togliere un override stretto non apre gli ambienti della org-wide che l'attore non vede" do
      membership.update!(secret_environment_codes: %w[staging production])
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: %w[staging production],
                                    per_project: { project.id => [] }, actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(per_project_codes).to eq([ "staging" ])
    end

    it "sul singolo progetto conta il confine dell'attore su QUEL progetto" do
      create(:account_secret_access, account: actor, project:, organization:, environment_codes: %w[staging production])
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [ "staging" ],
                                    per_project: { project.id => [ "production" ] }, actor:)

      expect(result).to be_ok
      expect(per_project_codes).to eq([ "production" ])
    end

    it "una modifica org-wide non apre un progetto su cui l'attore è più stretto" do
      actor_membership.update!(secret_environment_codes: [])
      create(:account_secret_access, account: actor, project:, organization:, environment_codes: [ "staging" ])
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [], actor:)

      expect(result.error.code).to eq("R403-ACCESS-001")
      expect(result.error.details[:project_id]).to eq(project.id)
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "una modifica org-wide è permessa se i progetti senza override del target restano nel confine dell'attore" do
      actor_membership.update!(secret_environment_codes: [])
      create(:account_secret_access, account: actor, project:, organization:, environment_codes: [ "staging" ])
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "staging" ])
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [], actor:)

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([])
      expect(per_project_codes).to eq([ "staging" ])
    end

    context "con un solo ambiente nell'organizzazione" do
      let(:solo) { create(:organization) }
      let!(:staging) { create(:environment, organization: solo, code: "staging") }
      let(:solo_actor) do
        create(:account).tap do |manager|
          create(:membership, account: manager, organization: solo, role: :member, secret_environment_codes: [ "staging" ])
        end
      end
      let(:solo_membership) { Connections::Membership.find_by(account: solo_actor, organization: solo) }

      it "svuotare la propria lista è rifiutato: il nuovo ambiente di domani resterebbe aperto" do
        result = described_class.call(membership: solo_membership, org_wide_codes: [], actor: solo_actor)

        expect(result.error.code).to eq("R403-ACCESS-001")
        expect(result.error.details[:unlimited]).to be(true)
        expect(solo_membership.reload.secret_environment_codes).to eq([ "staging" ])

        create(:environment, organization: solo, code: "production")
        expect(Secrets::EnvironmentAccess.new(account: solo_actor, project: create(:project, organization: solo))
                                          .allowed?("production")).to be(false)
      end

      it "togliere il limite a un collega è rifiutato" do
        colleague = create(:membership, organization: solo, role: :member, secret_environment_codes: [ "staging" ])

        result = described_class.call(membership: colleague, org_wide_codes: [], actor: solo_actor)

        expect(result.error.code).to eq("R403-ACCESS-001")
        expect(colleague.reload.secret_environment_codes).to eq([ "staging" ])
      end
    end

    it "un attore senza limiti (non owner) può aprire tutto" do
      actor_membership.update!(secret_environment_codes: [])
      membership.update!(secret_environment_codes: [ "staging" ])

      result = described_class.call(membership:, org_wide_codes: [], actor:)

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([])
    end

    it "il proprietario cambia o svuota gli ambienti come prima" do
      owner = create(:account)
      create(:membership, account: owner, organization:, role: :owner, secret_environment_codes: [ "staging" ])
      membership.update!(secret_environment_codes: [ "staging" ])

      expect(described_class.call(membership:, org_wide_codes: [ "production" ], actor: owner)).to be_ok
      expect(described_class.call(membership:, org_wide_codes: [], actor: owner)).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([])
    end

    it "l'amministratore della piattaforma (god) non ha vincoli" do
      god = create(:account, god: true)

      result = described_class.call(membership: actor_membership, org_wide_codes: [], actor: god)

      expect(result).to be_ok
    end

    # Rilettura CYRA-1118: due richieste concorrenti sullo stesso confine. A restringe (org-wide staging,
    # via l'override su P), B riconferma org-wide illimitata avendo letto il confine PRIMA di A: se B
    # verificasse quel confine vecchio, P diventerebbe illimitato senza che nessuno l'abbia verificato.
    context "con richieste concorrenti sulla propria membership" do
      let(:self_account) { create(:account) }
      let!(:self_membership) do
        create(:membership, account: self_account, organization:, role: :member, secret_environment_codes: [])
      end

      before do
        create(:account_secret_access, account: self_account, project:, organization:, environment_codes: [ "staging" ])
      end

      it "la richiesta arrivata dopo verifica il confine committato, non quello letto prima" do
        stale = Connections::Membership.find(self_membership.id)
        first = described_class.call(membership: self_membership, org_wide_codes: [ "staging" ],
                                     per_project: { project.id => [] }, actor: self_account)
        expect(first).to be_ok

        second = described_class.call(membership: stale, org_wide_codes: [], actor: self_account)

        expect(second.error.code).to eq("R403-ACCESS-001")
        expect(self_membership.reload.secret_environment_codes).to eq([ "staging" ])
        expect(Connections::AccountSecretAccess.where(account: self_account, project:)).to be_empty
      end

      it "legge e verifica il confine sotto lock delle membership coinvolte" do
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          described_class.call(membership:, org_wide_codes: [ "staging" ], actor: self_account)
        end

        locked = statements.find { |sql| sql.include?("FOR UPDATE") }
        expect(locked).to be_present
        expect(statements.index(locked)).to be < statements.index { |sql| sql.include?("connections_account_secret_accesses") }
      end
    end
  end

  it "è atomico: se l'override fallisce, l'allow-list org-wide non resta salvata" do
    allow(Connections::AccountSecretAccess).to receive(:find_or_initialize_by).and_raise(ActiveRecord::RecordInvalid.new(Connections::AccountSecretAccess.new))

    result = described_class.call(membership:, org_wide_codes: [ "staging" ],
                                  per_project: { project.id => [ "production" ] })

    expect(result).to be_err
    expect(membership.reload.secret_environment_codes).to eq([])
  end
end
