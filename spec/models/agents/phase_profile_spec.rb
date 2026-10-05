# frozen_string_literal: true

require "rails_helper"

# Modello host-first: è la FASE (execution_phase) — non un agente tipizzato — a determinare il profilo
# di esecuzione. Questa spec fissa il VOCABOLARIO CANONICO (execution_phase ≠ skill_key ≠ workflow_state)
# e la PARITÀ con la fonte sparsa attuale, invocandola DAVVERO (Command#write_access?, Save#runtime_profile,
# Command::RUNTIMES/KEYS, Agent::READ_ONLY_TOOLS) così un loro drift fa fallire il test.
#
# PIVOT CYAU-87: nel modello host-first le fasi WRITE (autopilot/closer_*) eseguono con **Claude headless**
# (runtime claude, permission_mode bypassPermissions, sandbox workspace-write, allowed_tools []), NON più con
# Codex — Codex resta solo cross-reviewer. La parità legacy resta PIENA per le fasi READ (triage/planner) e
# PARZIALE per le WRITE (condividono sandbox/allowed_tools/write_access? con la fonte legacy, ma runtime e
# permission_mode DIVERGONO deliberatamente: la fonte legacy Command::RUNTIMES/Save resta codex/nil finché il
# sistema typed-agent non viene rimosso — CYAU-85).
RSpec.describe Agents::PhaseProfile do
  let(:read_phases) { %w[triage planner] }
  let(:write_phases) { %w[autopilot closer_staging closer_production] }

  describe "vocabolario canonico delle fasi" do
    it "elenca esattamente le 5 execution_phase del flusso host-first" do
      expect(described_class.phases).to eq(%w[triage planner autopilot closer_staging closer_production])
    end

    it "mappa ogni fase alla sua skill_key con la regola /closeyourit-<fase con trattini>" do
      described_class.phases.each do |phase|
        expect(described_class.for(phase).skill_key).to eq("/closeyourit-#{phase.tr('_', '-')}")
      end
    end

    it "tiene execution_phase e skill_key come vocabolari distinti (una fase non è la sua skill)" do
      described_class.phases.each do |phase|
        expect(described_class.for(phase).skill_key).not_to eq(phase)
      end
    end
  end

  describe "derivabilità dalla sola fase (senza agente)" do
    it "espone il profilo completo per ogni fase" do
      profile = described_class.for("triage")
      expect(profile.to_h).to eq(
        skill_key: "/closeyourit-triage", runtime: "claude", sandbox: nil,
        permission_mode: "bypassPermissions", allowed_tools: %w[Read Glob Grep], ttl: 3600
      )
    end

    it "restituisce nil per una fase sconosciuta (fail-closed, nessuna eccezione)" do
      expect(described_class.for("nope")).to be_nil
      expect(described_class.for(nil)).to be_nil
      expect(described_class.known?("nope")).to be(false)
    end

    it "accetta sia simbolo sia stringa come chiave di fase" do
      expect(described_class.for(:triage)).to eq(described_class.for("triage"))
    end
  end

  describe "contratto delle fasi (il profilo È la fonte, non una copia da tenere allineata)" do
    # La sola-lettura delle fasi READ è la SANDBOX ASSENTE, non il permission_mode: senza worktree gestito
    # l'hook `require-worktree` nega ogni Edit/Write. Il permission_mode serve a tutt'altro — a far ESEGUIRE
    # gli script della skill, che legge il ticket con `cyi` e compone il risultato con gli helper node.
    it "le fasi READ non hanno accesso in scrittura: nessuna sandbox, nessun worktree" do
      read_phases.each do |phase|
        profile = described_class.for(phase)
        expect(profile.allowed_tools).to eq(%w[Read Glob Grep])
        expect(profile.sandbox).to be_nil
        expect(profile.write_access?).to be(false)
      end
    end

    # Regressione del 2026-07-30: le fasi READ giravano in `plan`, dove Claude NON esegue. Ogni chiamata Bash
    # della skill finiva negata, la sessione si arrendeva scrivendo in prosa e nessuna lavorazione veniva mai
    # conclusa. In headless non esiste un approvatore: qualunque modalità diversa da `bypassPermissions`
    # riporterebbe quel guasto.
    it "OGNI fase esegue davvero: in headless non c'è un approvatore, quindi mai `plan`" do
      described_class.phases.each do |phase|
        expect(described_class.for(phase).permission_mode).to eq("bypassPermissions"),
                                                              "la fase #{phase} non potrebbe eseguire i propri script"
      end
    end

    it "le fasi WRITE sono confinate dalla sandbox, non da una whitelist di tool" do
      write_phases.each do |phase|
        profile = described_class.for(phase)
        expect(profile.sandbox).to eq("workspace-write")
        expect(profile.allowed_tools).to eq([])
        expect(profile.write_access?).to be(true)
      end
    end

    it "l'insieme delle skill_key copre le cinque fasi senza duplicati" do
      keys = described_class.phases.map { |phase| described_class.for(phase).skill_key }
      expect(keys.uniq.size).to eq(5)
      expect(keys).to contain_exactly("/closeyourit-triage", "/closeyourit-planner", "/closeyourit-autopilot",
                                      "/closeyourit-closer-staging", "/closeyourit-closer-production")
    end
  end

  # PIVOT CYAU-87: contratto host-first delle fasi WRITE. Claude implementa/rilascia tutte le fasi (ha il plugin
  # system → SKILL_DIR risolto); Codex resta solo cross-reviewer. La write autonoma headless necessita
  # bypassPermissions (Bash senza prompt) + i guardrail dell'automator che impongono la sicurezza.
  describe "policy host-first delle fasi write (PIVOT CYAU-87: Claude headless, non Codex)" do
    it "esegue ogni fase write con Claude bypassPermissions in sandbox workspace-write, senza whitelist di tool" do
      write_phases.each do |phase|
        profile = described_class.for(phase)
        expect(profile.runtime).to eq("claude")
        expect(profile.permission_mode).to eq("bypassPermissions")
        expect(profile.sandbox).to eq("workspace-write")
        expect(profile.allowed_tools).to eq([])
        expect(profile.ttl).to eq(3600)
        expect(profile.write_access?).to be(true)
      end
    end

    it "esegue ogni fase write con Claude headless: Codex resta solo cross-reviewer" do
      write_phases.each do |phase|
        expect(described_class.for(phase).runtime).to eq("claude")
      end
    end
  end

  describe "TTL (policy host-first: per-fase, in parità con gli agenti tipizzati a 3600)" do
    it "vale esattamente 3600 secondi per ogni fase" do
      described_class.phases.each do |phase|
        expect(described_class.for(phase).ttl).to eq(3600)
      end
    end
  end

  # CYRA-285: la rilettura incrociata resta obbligatoria ovunque, ma quanto deve essere profonda lo decide
  # la FASE, non l'host.
  describe "#review_depth (profondità della rilettura incrociata)" do
    it "chiede alle fasi read la sola rilettura del result strutturato" do
      read_phases.each do |phase|
        expect(described_class.for(phase).review_depth).to eq("result")
      end
    end

    it "chiede la rilettura piena del diff alla sola fase che scrive codice" do
      expect(described_class.for("autopilot").review_depth).to eq("diff")
    end

    # CYAU-176 — il cuore del ticket. Le due fasi che rilasciano HANNO il permesso di scrivere, ma non
    # scrivono codice: uniscono e mettono l'etichetta di versione. E quando un rilascio è riuscito le
    # modifiche non sono più in attesa, sono già dentro il ramo principale: da confrontare non resta
    # niente, il controllo andava a vuoto e la lavorazione risultava fallita a rilascio perfettamente
    # riuscito — cioè la produzione non partiva.
    it "NON chiede il diff alle due fasi che rilasciano, che un diff da rileggere non ce l'hanno" do
      %w[closer_staging closer_production].each do |phase|
        profile = described_class.for(phase)
        expect(profile.write_access?).to be(true), "#{phase} dovrebbe poter scrivere nel repository"
        expect(profile.review_depth).to eq("result")
      end
    end

    # La derivazione da `write_access?` è ciò che ha prodotto il guasto: "questa fase può scrivere" e
    # "questa fase ha un diff da rileggere" non sono la stessa domanda, e dedurre l'una dall'altra rompe
    # esattamente dove le due risposte divergono.
    it "non si deduce dal permesso di scrittura" do
      divergenti = described_class.phases.select do |phase|
        profile = described_class.for(phase)
        profile.review_depth != (profile.write_access? ? "diff" : "result")
      end

      expect(divergenti).to contain_exactly("closer_staging", "closer_production")
    end

    # Una fase nuova che non si dichiara non eredita una profondità in silenzio: resta nil, e
    # Attempts::Deliver è fail-closed su nil.
    it "resta nulla su una fase sconosciuta, invece di indovinare" do
      expect(described_class.for("fase_che_non_esiste")).to be_nil
      expect(described_class::REVIEW_DEPTHS.keys).to match_array(described_class.phases)
    end

    # NON è un parametro di esecuzione della sessione: il profilo viene denormalizzato sulle colonne
    # immutabili dell'attempt (`assign_attributes(**profile.to_h)`) e concorre al digest pinnato sul lease.
    # Mettercela dentro pretenderebbe una colonna nuova e invaliderebbe ogni lease in volo, senza che nulla
    # di come la sessione gira sia cambiato.
    it "non entra nel profilo denormalizzato né sposta il digest pinnato sul lease" do
      described_class.phases.each do |phase|
        profile = described_class.for(phase)
        expect(profile.to_h).not_to have_key(:review_depth)
        expected = Digest::SHA256.hexdigest(JSON.generate(profile.to_h.sort_by { |key, _| key.to_s }.to_h))
        expect(profile.digest).to eq(expected)
      end
    end
  end

  describe "immutabilità profonda delle costanti (garanzia di sicurezza)" do
    it "non permette di mutare allowed_tools di una fase write a runtime" do
      expect { described_class.for(:autopilot).allowed_tools << "Bash" }.to raise_error(FrozenError)
      # e la costante condivisa resta intatta per la fetch successiva
      expect(described_class.fetch(:autopilot).allowed_tools).to eq([])
    end

    it "non permette di mutare allowed_tools di una fase claude a runtime" do
      expect { described_class.for(:triage).allowed_tools << "Bash" }.to raise_error(FrozenError)
    end

    it "espone valori congelati anche attraverso to_h" do
      expect { described_class.for(:triage).to_h[:allowed_tools] << "Bash" }.to raise_error(FrozenError)
    end

    it "congela l'hash degli attributi di ogni fase" do
      described_class.phases.each do |phase|
        expect(Agents::PhaseProfile::PROFILES.fetch(phase)).to be_frozen
      end
    end
  end

  describe "identità stabile dell'oggetto" do
    it "non dipende da una stringa esterna mutata dopo la costruzione" do
      mutable = +"triage"
      profile = described_class.for(mutable)
      mutable << "-tampered"
      expect(profile.phase).to eq("triage")
      expect(profile.skill_key).to eq("/closeyourit-triage")
    end

    it "ha hash stabile e uguaglianza per fasi uguali, disuguaglianza per fasi diverse" do
      expect(described_class.for(:autopilot).hash).to eq(described_class.for("autopilot").hash)
      expect(described_class.for(:autopilot)).to eq(described_class.for("autopilot"))
      expect(described_class.for(:autopilot)).not_to eq(described_class.for("triage"))
    end

    it "è utilizzabile come chiave di Hash" do
      table = { described_class.for(:triage) => :ok }
      expect(table[described_class.for("triage")]).to eq(:ok)
    end

    it "espone #known? d'istanza" do
      expect(described_class.for(:triage).known?).to be(true)
    end
  end

  describe "il profilo sceglie solo valori server-ammessi (mai indebolisce i guardrail)" do
    # Valori reali accettati dalle CLI: `claude --permission-mode` e `codex --sandbox`. Un profilo che ne
    # inventasse uno fuori lista produrrebbe uno spawn rifiutato a valle, non una sessione più permissiva.
    permission_modes = %w[plan acceptEdits auto manual dontAsk bypassPermissions].freeze
    sandbox_modes = %w[read-only workspace-write].freeze
    read_only_tools = %w[Read Glob Grep].freeze

    it "usa solo permission_mode realmente accettati da claude" do
      described_class.phases.each do |phase|
        mode = described_class.for(phase).permission_mode
        expect(mode).to be_nil.or(satisfy { |m| permission_modes.include?(m) })
      end
    end

    it "usa solo sandbox realmente accettate" do
      described_class.phases.each do |phase|
        sandbox = described_class.for(phase).sandbox
        expect(sandbox).to be_nil.or(satisfy { |s| sandbox_modes.include?(s) })
      end
    end

    it "non concede mai tool di scrittura/esecuzione: gli allowed_tools sono un sottoinsieme dei read-only" do
      described_class.phases.each do |phase|
        tools = described_class.for(phase).allowed_tools
        expect(tools - read_only_tools).to be_empty
        expect(tools).not_to include("Bash", "Write", "Edit")
      end
    end

    it "non affida mai una whitelist di tool alle fasi write (la sandbox workspace-write governa la scrittura)" do
      write_phases.each { |phase| expect(described_class.for(phase).allowed_tools).to eq([]) }
    end
  end

  describe ".fetch (accesso stretto)" do
    it "solleva KeyError per una fase sconosciuta" do
      expect { described_class.fetch("nope") }.to raise_error(KeyError)
    end

    it "restituisce il profilo per una fase valida" do
      expect(described_class.fetch("autopilot").runtime).to eq("claude")
    end
  end

  # profile_digest host-first (CYAU-96): impronta canonica del profilo di esecuzione della fase, pinnata sul
  # lease alla presa e riconfrontata fail-closed alla consegna. La Selection firmerà lo stesso digest (CYAU-79/80).
  describe "#digest (impronta canonica del profilo di fase)" do
    it "è un digest SHA256 esadecimale a 64 caratteri" do
      expect(described_class.for("triage").digest).to match(/\A[0-9a-f]{64}\z/)
    end

    it "è stabile per la stessa fase tra invocazioni distinte (simbolo o stringa)" do
      expect(described_class.for("triage").digest).to eq(described_class.for(:triage).digest)
    end

    it "è distinto per ognuna delle 5 fasi (nessuna collisione)" do
      digests = described_class.phases.map { |phase| described_class.for(phase).digest }
      expect(digests.uniq.size).to eq(described_class.phases.size)
    end

    it "è funzione canonica (ordine-indipendente) degli attributi del profilo" do
      described_class.phases.each do |phase|
        profile = described_class.for(phase)
        expected = Digest::SHA256.hexdigest(JSON.generate(profile.to_h.sort_by { |key, _| key.to_s }.to_h))
        expect(profile.digest).to eq(expected)
      end
    end
  end
end
