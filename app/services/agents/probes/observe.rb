# frozen_string_literal: true

module Agents
  module Probes
    # CYRA-624 — va a guardare se il rilascio è DAVVERO in piedi, e solo allora il ticket è «Fatto».
    #
    # Prima il ticket diventava Fatto nell'istante in cui la macchina diceva di aver messo l'etichetta
    # della versione. In quel momento non era stato rilasciato niente: il rilascio parte dopo, e può
    # andare male un minuto dopo. Il ticket restava Fatto lo stesso, e nessuno veniva avvisato.
    #
    # Tre fatti, e servono tutti e tre:
    #   1. l'etichetta della versione sta esattamente sul codice sigillato — non su qualcosa che gli
    #      somiglia e nemmeno su qualcosa che ci sta sopra;
    #   2. il giro di rilascio è girato davvero, e i due passaggi che contano sono finiti bene;
    #   3. la produzione ha risposto con quella versione e con quel codice, e qualcuno l'ha vista.
    class Observe < ApplicationService
      # I due passaggi che contano. I nomi arrivano da un file di lavorazione richiamato, quindi nella
      # lista del giro portano il prefisso del lavoro che li richiama: si confronta l'ULTIMO pezzo.
      #
      # Non basta che il giro nel suo insieme sia verde: un giro con questi passaggi SALTATI resta
      # verde, e saltato vuol dire che non è stato fatto niente.
      STEPS = %w[deploy-production smoke-prod].freeze
      SUCCESS = "success"
      # Esiti che dicono «è andata male», non «non ancora». `nil` è ancora in corso e non sta qui.
      FAILED_CONCLUSIONS = %w[failure cancelled timed_out startup_failure].freeze

      def initialize(probe:, client: nil, now: Time.current)
        @probe = probe
        @workflow = probe.workflow
        @client = client
        @now = now
      end

      def call
        return Result.ok(@probe) unless @probe.live?
        return check_registry if @probe.kind == "publish"

        commit = tag_commit
        return not_yet("tag_missing") if commit.blank?
        # Nemmeno «ci sta sopra»: un commit che DISCENDE dal codice sigillato non è il codice
        # sigillato, e pubblicarlo vorrebbe dire aver messo fuori righe che nessuno ha guardato.
        return not_yet("tag_mismatch", tag_commit: commit) if commit != @probe.expected_sha

        runs = release_runs(commit)
        # Un rilascio andato male non è «non ancora»: è una cosa che una persona deve guardare, e
        # aspettare un'ora per dirglielo vorrebbe dire tenerla al buio mentre la produzione è ferma.
        return stop!("release_run_failed") if runs.any? { |_, outcome| FAILED_CONCLUSIONS.include?(outcome) }
        return not_yet("release_run_missing") unless runs.any? { |succeeded, _| succeeded }
        return not_yet("release_not_proved") unless row_proved?

        close!
      rescue Github::Client::Error => e
        # Una linea rotta non è un rilascio andato male: si aspetta e si riprova, e non si chiama
        # nessuno. Confonderle vorrebbe dire svegliare una persona per un timeout.
        not_yet(e.code)
      end

      private

      # ── CYRA-625 ────────────────────────────────────────────────────────────────────────────────
      #
      # Sei progetti non mettono online un sito: pubblicano un pacchetto. Per quelli il sistema non
      # chiede al lavoro di pubblicazione com'è andata — «finito senza errori» non è «il pacchetto è
      # sullo scaffale»: sul progetto Python l'etichetta stava nel repository da due settimane e
      # mezzo mentre il magazzino portava ancora la versione precedente.
      #
      # Va a guardare da fuori, come farebbe chi installa, e pretende tre cose insieme.
      def check_registry
        registry = Agents::Registries::Client.for(@probe.expected_registry)
        return not_yet("registry_unknown") if registry.nil?

        outcome = registry.lookup(@probe.expected_package, package_version)
        evidence = { "registry_url" => outcome[:url], "registry_latest" => outcome[:latest] }
        return not_yet("package_missing", **evidence) unless outcome[:present]
        return not_yet("package_yanked", **evidence) if outcome[:yanked]
        return not_yet("latest_not_stable", **evidence) unless latest_acceptable?(outcome[:latest])
        return not_yet("git_head_mismatch", **evidence.merge("registry_sha" => outcome[:sha])) unless
          identity_confirmed?(outcome[:sha])

        close!
      rescue Agents::Registries::Client::Error => e
        # Timeout, 5xx, troppe richieste, corpo illeggibile: è una linea storta, non una negazione.
        # Il nome del pacchetto fuori alfabeto invece è una cosa che una persona deve sistemare, ma
        # non prima che la finestra scada: non è un guasto che si aggiusta da solo, e nemmeno una
        # ragione per svegliare qualcuno prima del tempo.
        not_yet(e.code)
      end

      # La versione cercata è quella del TAG SIGILLATO, mai quella scritta in un file del repository:
      # su quattro progetti su sei il numero pubblicato veniva da lì, e non lo confrontava nessuno.
      def package_version = @probe.expected_version.to_s.delete_prefix("v")

      # Il puntatore «ultima buona» dev'essere QUELLA versione o una definitiva successiva. Mai una
      # di prova: quella la prendono tutti quelli che installano senza chiedere una versione, ed è
      # esattamente il difetto trovato su JavaScript e riga di comando.
      def latest_acceptable?(latest)
        return false if latest.blank?
        return false unless stable?(latest)

        (comparable_version(latest) <=> comparable_version(package_version)) >= 0
      end

      # Definitiva = solo cifre e punti. Ogni registro scrive le prove a modo suo — `-beta.1` su npm
      # e pub.dev, `.rc1` su RubyGems, `rc1` su PyPI — e tutte e tre hanno in comune di non essere
      # solo cifre.
      def stable?(version) = /\A\d+(\.\d+)*\z/.match?(version.to_s)

      # Confronto pezzo per pezzo, riempiendo con zeri: `0.11` e `0.11.0` sono la stessa versione, e
      # confrontarle come testo direbbe di no.
      def comparable_version(version)
        parts = version.to_s.split(".").map(&:to_i)
        parts.fill(0, parts.length...3)
      end

      # Dove il magazzino dichiara da quale codice il pacchetto è stato costruito — succede su npm —
      # quel codice dev'essere esattamente quello sigillato all'approvazione. Il confronto è per
      # intero: un prefisso non è un'identità, in nessuno dei due versi. Campo assente: non passa.
      def identity_confirmed?(sha)
        return true unless @probe.expected_registry == "npm"

        sha.present? && sha == @probe.expected_sha
      end

      def client = @client ||= Github::Client.new

      def installation = @workflow.ticket.project.github_repository&.github_installation_id

      def repo = @probe.expected_repo

      def tag_commit
        client.tag_commit(installation, repo, @probe.expected_version)
      end

      # I giri di RILASCIO partiti su quel commit: quelli che contengono almeno uno dei due passaggi.
      # Sullo stesso commit girano anche altre lavorazioni, e fermare tutto perché un controllo di
      # stile è rosso vorrebbe dire chiamare una persona per una cosa che col rilascio non c'entra.
      #
      # Di ognuno si restituisce se è riuscito DAVVERO — i due passaggi entrambi «riuscito» — e il suo
      # esito complessivo. Non basta il verde del giro: un giro con quei passaggi SALTATI resta verde,
      # e saltato vuol dire che non è stato fatto niente.
      def release_runs(commit)
        client.workflow_runs(installation, repo, commit).filter_map do |run|
          jobs = client.workflow_run_jobs(installation, repo, run["id"])
          ours = jobs.select { |job| STEPS.include?(name_tail(job["name"])) }
          next if ours.empty?

          succeeded = STEPS.all? do |step|
            ours.any? { |job| name_tail(job["name"]) == step && job["conclusion"] == SUCCESS }
          end
          [ succeeded, run["conclusion"] ]
        end
      end

      def name_tail(name) = name.to_s.split("/").last.to_s.strip

      # La riga di rilascio con QUELLA versione, in produzione, con QUEL codice, e con l'istante di
      # prova scritto — che lo scrive solo il canale della CI dopo il controllo finale. Mai «l'ultimo
      # rilascio registrato»: l'ultimo può essere di un altro lavoro.
      def row_proved?
        row = @workflow.ticket.project.releases.find_by(
          version: @probe.expected_version, environment: Projects::Release::DEFAULT_ENVIRONMENT
        )
        return false if row.nil? || row.proved_at.blank? || row.sha.blank?

        row.sha == @probe.expected_sha
      end

      # Le tre scritture insieme: se una non riesce non ne resta nessuna. Un ticket «Fatto» con la
      # prova ancora agganciata verrebbe riguardato per sempre; una prova chiusa con il ticket non
      # Fatto sparirebbe in silenzio.
      def close!
        rejected = false
        ActiveRecord::Base.transaction do
          state = @workflow.organization.ticket_statuses.active.category_done.ordered.first
          raise ActiveRecord::RecordNotFound, "Stato done non configurato" if state.nil?

          @probe.update!(closed_at: @now, next_check_at: nil, last_error_code: nil,
                         evidence: @probe.evidence.merge("closed_by" => "probe", "at" => @now))
          @workflow.update!(completed_at: @now)
          outcome = Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket: @workflow.ticket,
                                               status_id: state.id, channel: :workflow)
          # CYRA-597 — il cancello dei prerequisiti vive dentro quella porta, e qui la sua parola
          # vale: un ticket portato a «fatto» con un prerequisito ancora aperto non lo guarda più
          # nessuno. Se rifiuta non resta NIENTE — né il lavoro concluso né la prova chiusa —
          # altrimenti resterebbe una lavorazione finita su un ticket fermo.
          next if outcome.ok?

          rejected = true
          raise ActiveRecord::Rollback
        end
        return not_yet("dependency_blocked") if rejected

        Result.ok(@probe)
      end

      # Non ancora: si segna cosa si è visto, si conta il tentativo e si torna a guardare fra due
      # minuti. Passata l'ora, non è più «non ancora»: è qualcosa che una persona deve guardare.
      def not_yet(code, **evidence)
        @probe.update!(last_error_code: code, checks_count: @probe.checks_count + 1,
                       next_check_at: @now + Agents::WorkflowProbe::RETRY_EVERY,
                       evidence: @probe.evidence.merge(evidence.transform_keys(&:to_s)))
        return Result.ok(@probe) unless @probe.expired?(@now)

        stop!("release_proof_timeout")
      end

      # Fermarsi passa dalla porta unica (CYRA-618): il motivo porta da DOVE il fatto è stato visto.
      def stop!(reason)
        Agents::Workflows::BlockExhaustedPhase.call(
          workflow: @workflow, phase: "closer_production", source: "release_probe",
          kind: "release_probe", reason: "#{reason} on #{repo} #{@probe.expected_version}"
        )
        Result.ok(@probe)
      end
    end
  end
end
