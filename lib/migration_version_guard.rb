# frozen_string_literal: true

require "open3"
require "pathname"

# CYRA-589 — Due lavorazioni aperte nello stesso minuto generano una migration con lo STESSO
# timestamp. Git al merge non vede nessun conflitto: sono due file con nomi diversi. Da lì in poi la
# collisione ha due esiti, tutti e due tardivi:
#
#   1. il database ha già registrato quella versione (l'altro ramo è passato di lì) e vede il file
#      nuovo: `pending_migrations` la salta perché risulta applicata, `db:migrate` esce con successo,
#      la tabella o la colonna non esistono e il guasto salta fuori molto dopo, da un errore che
#      sembra non c'entrare niente — è il caso silenzioso, capitato due volte in un giorno solo;
#   2. i due file finiscono entrambi in `db/migrate`: `Migrator#validate` alza
#      `ActiveRecord::DuplicateMigrationVersionError: Multiple migrations have the version number N`
#      e da quel momento `db:migrate` non parte più per nessuno, nemmeno per chi non c'entra.
#
# Nessun isolamento lo evita — sono due rami che scelgono lo stesso intero, ognuno ignorando l'altro.
# L'unica difesa è renderlo rumoroso PRIMA della consegna, ed è quello che fa questa classe.
#
# Confronta i FILE, non il database: nel giro automatico il database del ramo nasce vuoto e applica
# tutto, quindi lì la collisione non si vede. Quello che si vede è che due file di `db/migrate`
# portano lo stesso numero, uno nel ramo e uno già sul ramo principale.
class MigrationVersionGuard
  DEFAULT_BASE_REF = "origin/main"
  MIGRATION_DIRECTORY = "db/migrate"
  MIGRATION_FILENAME = /\A(\d+)_.+\.rb\z/

  # `existing_ref` è il ramo dove il numero era già preso; `nil` quando le due migration stanno
  # entrambe nel ramo corrente (stesso guasto, sorgente diversa: due sessioni merge-ate in locale).
  Collision = Data.define(:version, :incoming, :existing, :existing_ref)

  Verdict = Data.define(:base_ref, :comparable, :collisions) do
    def clean? = collisions.empty?

    def comparable? = comparable

    def message
      return uncomparable_message unless comparable
      return "Nessuna collisione: ogni migration porta una versione sua." if clean?

      ([ "Versioni di migration già usate:" ] + collisions.map { |collision| " - #{describe(collision)}" } +
        [ CONSEQUENCE, REMEDY ]).join("\n")
    end

    private

    def describe(collision)
      where = collision.existing_ref ? "su #{collision.existing_ref}" : "in questo ramo"

      "#{MIGRATION_DIRECTORY}/#{collision.incoming} porta la versione #{collision.version}, " \
        "già presa #{where} da #{collision.existing}"
    end

    def uncomparable_message
      "Versioni delle migration: non ho potuto confrontare con #{base_ref}. Il riferimento non " \
        "esiste qui (storia parziale o remoto non aggiornato): finché manca, questo controllo non " \
        "garantisce niente."
    end
  end

  # Il testo non dice soltanto «numero duplicato», che suona come una formalità di stile: dice cosa
  # succede a lasciarlo passare, perché è l'unica parte che spiega perché vale fermarsi.
  CONSEQUENCE = <<~TEXT.chomp
    Cosa succede se resta così: dove quella versione è già registrata in schema_migrations la
    migration non verrà eseguita e nessuno lo segnala — db:migrate finisce con successo, la tabella
    o la colonna non esistono, e il guasto salta fuori molto dopo da un errore che sembra non
    c'entrare niente. Dove invece finiscono in db/migrate tutti e due i file, db:migrate non parte
    più per nessuno: ActiveRecord::DuplicateMigrationVersionError, Multiple migrations have the
    version number.
  TEXT

  REMEDY = <<~TEXT.chomp
    Come si esce: rinomina il file dandogli un timestamp nuovo (il nome della classe dentro al file
    non cambia), poi rilancia `bin/rails db:migrations:collisions`.
  TEXT

  def self.call(root:, base_ref: DEFAULT_BASE_REF)
    new(root: root, base_ref: base_ref).call
  end

  def initialize(root:, base_ref: DEFAULT_BASE_REF)
    @root = Pathname.new(root.to_s)
    @base_ref = base_ref
  end

  def call
    return Verdict.new(base_ref: @base_ref, comparable: false, collisions: []) unless base_ref_reachable?

    Verdict.new(base_ref: @base_ref, comparable: true, collisions: collisions)
  end

  private

  attr_reader :root, :base_ref

  def collisions
    on_base = migrations_on_base.group_by { |name| version_of(name) }

    working_tree_migrations.group_by { |name| version_of(name) }.sort.filter_map do |version, here|
      taken = on_base.fetch(version, [])
      newcomers = here - taken

      next if newcomers.empty? # sono le migration già mergiate: la versione è la loro

      if taken.any?
        Collision.new(version: version, incoming: newcomers.first, existing: taken.first, existing_ref: base_ref)
      elsif newcomers.size > 1
        Collision.new(version: version, incoming: newcomers.last, existing: newcomers.first, existing_ref: nil)
      end
    end
  end

  def working_tree_migrations
    directory = root.join(MIGRATION_DIRECTORY)
    return [] unless directory.directory?

    directory.children.map { |path| path.basename.to_s }.select { |name| name.match?(MIGRATION_FILENAME) }.sort
  end

  def migrations_on_base
    listing, status = git("ls-tree", "-r", "-z", "--name-only", base_ref, "--", MIGRATION_DIRECTORY)
    return [] unless status.success?

    listing.split("\0").map { |path| File.basename(path) }.select { |name| name.match?(MIGRATION_FILENAME) }.sort
  end

  def base_ref_reachable?
    _output, status = git("rev-parse", "--verify", "--quiet", "#{base_ref}^{commit}")
    status.success?
  end

  def version_of(filename)
    filename[MIGRATION_FILENAME, 1]
  end

  def git(*arguments)
    Open3.capture2("git", *arguments, chdir: root.to_s, err: File::NULL)
  end
end
