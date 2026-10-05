# frozen_string_literal: true

module Projects
  # Release di un progetto: la versione che gira (tag/sha/build). Nasce in due modi — upsert
  # esplicito dalla CI (POST /api/v1/projects/:id/releases con sha/build_time) o implicito
  # dall'ingest errori (primo evento che porta quella `release`). Aggancia gli errori per
  # versione: "introdotto in", "visto l'ultima volta in", regressioni post-release.
  class Release < ApplicationRecord
    self.table_name = "projects_releases"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :releases

    # Celle della matrice funzionalità che indicano questa release come "disponibile da" (CYRA-256).
    # Nullify: le release possono essere potate, la cella sopravvive perdendo solo la versione.
    has_many :feature_platforms,
             class_name: "Connections::FeaturePlatform",
             foreign_key: :release_id,
             inverse_of: :release,
             dependent: :nullify

    normalizes :version, with: ->(value) { value.to_s.strip }
    normalizes :environment, with: ->(value) { value.to_s.strip.downcase }

    validates :version, presence: true, uniqueness: { scope: %i[project_id environment] }
    validates :environment, presence: true

    scope :recent, -> { order(created_at: :desc) }
    # Release "live" per environment: marcata dal binding (Github::Releases::Reconcile). Indice
    # parziale unico [project_id, environment] WHERE current → al più una per environment.
    scope :current, -> { where(current: true) }

    # Environment di default quando l'evento/chiamante non lo dichiara.
    DEFAULT_ENVIRONMENT = "production"

    # Una `version` è "SHA-shaped" quando è una commit SHA esadecimale (7-40 char lowercase) invece
    # di un tag leggibile: le release nate dall'ingest (track_event!) portano in `version` il campo
    # `release` del payload SDK, che è spesso il commit hash grezzo. I tag reali (v1.2.3) NON matchano.
    SHA_SHAPED = /\A[0-9a-f]{7,40}\z/

    # True se `version` è una commit SHA grezza e non un tag di versione leggibile.
    def version_sha_shaped?
      SHA_SHAPED.match?(version.to_s)
    end

    # Identificatore da mostrare in UI (CYRA-9): un tag reale resta invariato; una version SHA-shaped
    # viene accorciata ai primi 7 char (come la colonna sha), così non compaiono i 40 char grezzi.
    def display_version
      version_sha_shaped? ? version.first(7) : version
    end

    # CYRA-44 — audit di regressione. Version della release "live" del progetto: la current in
    # produzione se presente, altrimenti la più recente marcata current. nil se il progetto non ha
    # un binding release (feature no-op → comportamento conservativo: ogni reopen è regressione).
    def self.live_version(project)
      live = project.releases.current
      release = live.find_by(environment: DEFAULT_ENVIRONMENT) || live.recent.first
      release&.version
    end

    # Istante di prima comparsa di una version nel progetto (min su tutti gli environment). Serve a
    # ORDINARE due release quando le stringhe version (SHA o tag misti) non sono confrontabili.
    def self.introduced_at(project:, version:)
      return nil if version.blank?

      where(project_id: project.id, version: version.to_s.strip)
        .minimum(Arel.sql("COALESCE(first_event_at, created_at)"))
    end

    # True/false se `version` è pari o successiva a `reference`; nil quando l'ordine è indeterminato
    # (una delle due blank, o SHA senza record release). Strategia: uguaglianza esatta → true;
    # confronto semver quando ENTRAMBE sono versioni valide (robusto anche per release mai viste);
    # altrimenti ordine di prima comparsa dei record release (fallback per SHA/tag non semver).
    def self.at_or_after?(project:, version:, reference:)
      current_version = version.to_s.strip
      reference_version = reference.to_s.strip
      return nil if current_version.blank? || reference_version.blank?
      return true if current_version == reference_version

      current_semver = semver(current_version)
      reference_semver = semver(reference_version)
      return current_semver >= reference_semver if current_semver && reference_semver

      current_at = introduced_at(project:, version: current_version)
      reference_at = introduced_at(project:, version: reference_version)
      return nil if current_at.nil? || reference_at.nil?

      current_at >= reference_at
    end

    # Gem::Version del tag (strip del prefisso `v`), o nil se non è un semver valido (es. commit SHA).
    def self.semver(value)
      core = value.to_s.strip.sub(/\Av/i, "")
      Gem::Version.correct?(core) ? Gem::Version.new(core) : nil
    end
    private_class_method :semver

    # Upsert atomico dall'ingest: crea la release al primo evento e aggiorna attività/contatore.
    # Una sola query (ON CONFLICT), sicura sotto concorrenza dei job. La chiave d'identità è
    # [progetto, version, environment]: stessa version in staging e production = due release.
    def self.track_event!(project:, version:, environment:, occurred_at:)
      return if version.blank?

      env = (environment.presence || DEFAULT_ENVIRONMENT).to_s.strip.downcase
      now = Time.current
      upsert_all(
        [ { project_id: project.id, version: version.strip, environment: env,
            first_event_at: occurred_at, last_event_at: occurred_at, events_count: 1,
            created_at: now, updated_at: now } ],
        unique_by: %i[project_id version environment],
        on_duplicate: Arel.sql(
          "events_count = projects_releases.events_count + 1, " \
          "first_event_at = LEAST(COALESCE(projects_releases.first_event_at, excluded.first_event_at), excluded.first_event_at), " \
          "last_event_at = GREATEST(COALESCE(projects_releases.last_event_at, excluded.last_event_at), excluded.last_event_at), " \
          "updated_at = excluded.updated_at"
        )
      )
    end
  end
end
