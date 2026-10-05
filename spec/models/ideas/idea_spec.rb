# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::Idea, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  describe "validazioni" do
    it "è valida con progetto, autore membro, titolo e corpo" do
      expect(build(:idea, organization: org, project: project)).to be_valid
    end

    it "rifiuta il titolo mancante (anche solo spazi, via normalizes)" do
      idea = build(:idea, organization: org, project: project, title: "   ")
      expect(idea).not_to be_valid
      expect(idea.errors[:title]).to be_present
    end

    it "rifiuta il problema mancante" do
      idea = build(:idea, organization: org, project: project, problem: "")
      expect(idea).not_to be_valid
      expect(idea.errors[:problem]).to be_present
    end

    it "normalizza monetizzazione e rischi (strip), entrambi opzionali" do
      idea = build(:idea, organization: org, project: project, monetization: "  boost  ", risks: "")
      expect(idea).to be_valid
      expect(idea.monetization).to eq("boost")
      expect(idea.risks).to eq("")
    end

    it "accetta la soluzione mancante (opzionale)" do
      idea = build(:idea, organization: org, project: project, solution: "")
      expect(idea).to be_valid
    end

    it "normalizza titolo, problema e soluzione (strip)" do
      idea = build(:idea, organization: org, project: project,
                          title: "  Dark mode  ", problem: "  il buio  ", solution: "  tema scuro  ")
      expect(idea.title).to eq("Dark mode")
      expect(idea.problem).to eq("il buio")
      expect(idea.solution).to eq("tema scuro")
    end

    it "normalizza gli stakeholder: strip, scarta i vuoti, dedup, mantiene il case" do
      idea = build(:idea, organization: org, project: project,
                          stakeholders: [ "  Team Mobile ", "", "  ", "Team Mobile", "Clienti" ])
      expect(idea.stakeholders).to eq([ "Team Mobile", "Clienti" ])
    end

    it "stakeholder di default è una lista vuota" do
      expect(build(:idea, organization: org, project: project).stakeholders).to eq([])
    end

    it "rifiuta un autore non membro dell'org del progetto (integrità tenant)" do
      outsider = create(:account)
      idea = build(:idea, organization: org, project: project, author: outsider)

      expect(idea).not_to be_valid
      expect(idea.errors[:author]).to be_present
    end

    it "accetta autore assente (idea sopravvissuta alla cancellazione dell'account)" do
      idea = create(:idea, organization: org, project: project)
      idea.update_column(:author_id, nil)
      expect(idea.reload).to be_valid
    end

    it "validatore tenant nil-safe: progetto non risolvibile → nessuna eccezione" do
      idea = described_class.new(title: "x", problem: "y", author: create(:account))
      expect { idea.valid? }.not_to raise_error
    end
  end

  describe "status" do
    it "nasce open" do
      expect(create(:idea, organization: org, project: project)).to be_status_open
    end

    it "espone i tre stati open/converted/archived" do
      expect(described_class.statuses.keys).to eq(%w[open converted archived])
    end

    it "locked? è falso solo per le idee open" do
      expect(build(:idea, status: :open)).not_to be_locked
      expect(build(:idea, status: :converted)).to be_locked
      expect(build(:idea, status: :archived)).to be_locked
    end
  end

  describe "#authored_by?" do
    it "riconosce l'autore e rifiuta gli altri (e nil)" do
      idea = create(:idea, organization: org, project: project)
      other = create(:account)

      expect(idea.authored_by?(idea.author)).to be(true)
      expect(idea.authored_by?(other)).to be(false)
      expect(idea.authored_by?(nil)).to be(false)
    end
  end

  describe "progetto immutabile (attr_readonly)" do
    it "rifiuta il cambio di project_id dopo la creazione" do
      idea = create(:idea, organization: org, project: project)
      altro = create(:project, organization: org)

      expect { idea.update(project_id: altro.id) }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(idea.reload.project_id).to eq(project.id)
    end
  end

  describe "relazioni 0/1/N" do
    it "senza commenti, voti né case i contatori sono a 0" do
      idea = create(:idea, organization: org, project: project)
      expect(idea.comments_count).to eq(0)
      expect(idea.votes_count).to eq(0)
      expect(idea.cases_count).to eq(0)
      expect(idea.comments).to be_empty
      expect(idea.cases).to be_empty
    end

    it "ordina i case per created_at e aggiorna cases_count" do
      idea = create(:idea, organization: org, project: project)
      vecchio = create(:idea_case, idea: idea, created_at: 2.hours.ago)
      nuovo = create(:idea_case, idea: idea, created_at: 1.minute.ago)

      expect(idea.cases.reload.map(&:id)).to eq([ vecchio.id, nuovo.id ])
      expect(idea.reload.cases_count).to eq(2)
    end

    it "ordina i commenti per created_at" do
      idea = create(:idea, organization: org, project: project)
      vecchio = create(:idea_comment, idea: idea, organization: org, created_at: 2.hours.ago)
      nuovo = create(:idea_comment, idea: idea, organization: org, created_at: 1.minute.ago)

      expect(idea.comments.reload.map(&:id)).to eq([ vecchio.id, nuovo.id ])
    end

    it "cascade destroy: commenti, voti e case cadono con l'idea" do
      idea = create(:idea, organization: org, project: project)
      create(:idea_comment, idea: idea, organization: org)
      create(:idea_vote, idea: idea)
      create(:idea_case, idea: idea)

      expect { idea.destroy }
        .to change(Ideas::Comment, :count).by(-1)
        .and change(Connections::IdeaVote, :count).by(-1)
        .and change(Ideas::Case, :count).by(-1)
    end

    it "cade col progetto" do
      idea = create(:idea, organization: org, project: project)
      expect { project.destroy }.to change { described_class.exists?(idea.id) }.to(false)
    end
  end

  describe "backlink ticket" do
    it "la cancellazione del ticket lascia l'idea converted senza link" do
      idea = create(:idea, :converted, organization: org, project: project)
      ticket = idea.ticket

      ticket.destroy
      idea.reload
      expect(idea).to be_status_converted
      expect(idea.ticket_id).to be_nil
    end

    it "un ticket non può nascere da due idee (unicità parziale su ticket_id)" do
      prima = create(:idea, :converted, organization: org, project: project)
      dupe = build(:idea, organization: org, project: project,
                          status: :converted, ticket: prima.ticket)

      expect { dupe.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#organization_id" do
    it "delega al progetto (radice di tenancy)" do
      idea = create(:idea, organization: org, project: project)
      expect(idea.organization_id).to eq(org.id)
    end
  end

  # CYRA-360 — il voto non ordina più niente: dice soltanto a quante persone interessa l'idea.
  # La bacheca si ordina per ultimo movimento, con la creazione come criterio di parità (senza,
  # due idee mai toccate finirebbero in ordine casuale).
  describe "scope di ordinamento" do
    it "by_last_activity mette per prima l'idea mossa più di recente, recent ordina per creazione" do
      vecchia = create(:idea, organization: org, project: project, created_at: 3.days.ago, updated_at: 3.days.ago)
      nuova = create(:idea, organization: org, project: project, created_at: 1.day.ago, updated_at: 1.day.ago)
      vecchia.touch

      expect(described_class.by_last_activity.map(&:id)).to eq([ vecchia.id, nuova.id ])
      expect(described_class.recent.map(&:id)).to eq([ nuova.id, vecchia.id ])
    end

    it "a parità di movimento decide la creazione, dalla più recente" do
      istante = 2.days.ago
      prima = create(:idea, organization: org, project: project, created_at: istante - 1.hour, updated_at: istante)
      dopo = create(:idea, organization: org, project: project, created_at: istante, updated_at: istante)

      expect(described_class.by_last_activity.map(&:id)).to eq([ dopo.id, prima.id ])
    end

    it "non esiste più un ordinamento per voti" do
      expect(described_class).not_to respond_to(:by_votes)
    end
  end

  # CYRA-360 — «ultimo movimento» deve essere vero, altrimenti è l'ennesimo segnale finto: la
  # discussione e i casi d'uso muovono l'idea, il voto no (per decisione di prodotto non sposta nulla).
  describe "ultimo movimento" do
    it "commento e caso d'uso lo aggiornano, il voto lo lascia fermo" do
      idea = create(:idea, organization: org, project: project, updated_at: 3.days.ago)

      expect { create(:idea_comment, idea: idea, organization: org) }.to(change { idea.reload.updated_at })
      expect { create(:idea_case, idea: idea) }.to(change { idea.reload.updated_at })
      expect { create(:idea_vote, idea: idea) }.not_to(change { idea.reload.updated_at })
    end
  end
end
