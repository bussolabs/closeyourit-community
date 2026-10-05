# frozen_string_literal: true

require "rails_helper"

# CYRA-743 — un file solo raccoglieva centoquindici costanti di dodici domini diversi, distinte
# soltanto dal prefisso nel nome: chi cercava la soglia di silenzio di una macchina e chi cercava il
# tetto di un commento aprivano lo stesso file di cinquecento righe e scorrevano il resto. Tre domini
# avevano già il proprio file (knowledge, ticketing, ai): il modello era deciso, mancava applicarlo.
#
# Qui si guarda il SORGENTE, non il comportamento: che il file generale contenga solo ciò che vale
# per tutti, che ogni dominio nominato abbia il suo file, e che nessun riferimento sia rimasto
# indietro. Il comportamento lo tengono le prove dei domini, che usano queste costanti per nome.
RSpec.describe "Le costanti stanno nel file del loro dominio", type: :model do
  let(:file_generale) { Rails.root.join("app/constants/app/constants.rb") }

  # Le uniche costanti che restano nel file generale: quelle che NON appartengono a un dominio —
  # le lingue dell'interfaccia, le densità di pagina, i tetti degli allegati condivisi dai concern
  # Attachable e Iconable. Se questo elenco cresce, il cassetto sta tornando.
  let(:costanti_generali) do
    %w[
      LOCALES TABLE_PER_PAGE API_PAGE_SIZE LENGTH_WARN_RATIO
      ATTACHMENT_MAX_SIZE ATTACHMENT_CONTENT_TYPES VIDEO_MAX_SIZE VIDEO_CONTENT_TYPES
      DOCUMENT_MAX_SIZE DOCUMENT_CONTENT_TYPES
      ICON_IMAGE_MAX_SIZE ICON_IMAGE_CONTENT_TYPES
    ]
  end

  it "il file generale definisce soltanto le costanti valide per tutti" do
    definite = App::Constants.constants.map(&:to_s).sort

    expect(definite).to eq(costanti_generali.sort),
                        "Il file generale definisce #{(definite - costanti_generali).join(', ')} in più e " \
                        "#{(costanti_generali - definite).join(', ')} in meno. Ciò che appartiene a un " \
                        "dominio vive nel file di quel dominio."
  end

  # Il tetto della Definition of Done, misurato sul file e non sul numero di costanti: sopra questa
  # misura il file generale ha ricominciato a raccogliere quello che non sa dove mettere.
  it "il file generale sta sotto le centoventi righe" do
    misura = Pathname(file_generale).readlines.size

    expect(misura).to be <= 120,
                      "Il file generale misura #{misura} righe: quello che è cresciuto appartiene a un dominio."
  end

  # I dodici domini del ticket, ciascuno col proprio file. Il valore accanto è la costante che ne
  # è il cuore: verifica insieme che il file esista, che sia caricabile e che il contenuto sia
  # arrivato davvero (un modulo vuoto passerebbe il solo const_defined?).
  {
    "Accounts::Constants" => :SESSION_ABSOLUTE_TTL,
    "Agents::Constants" => :PHASE_REVIEW_LIMIT,
    "Analytics::Constants" => :SESSION_GAP,
    "Changelog::Constants" => :MODAL_RELEASES,
    "Connections::Constants" => :TTL_INVITATION,
    "Errors::Constants" => :SPIKE_MIN_COUNT,
    "Logs::Constants" => :FACETS_CACHE_TTL,
    "Metrics::Constants" => :THRESHOLD_ALERT_COOLDOWN,
    "Monitoring::Constants" => :TELEMETRY_FULL_FIDELITY_COUNT,
    "Projects::Constants" => :SOURCE_FRESH_WITHIN,
    "Replays::Constants" => :MAX_BATCH,
    "Secrets::Constants" => :ROTATION_DUE_SOON_DAYS,
    "Servers::Constants" => :SILENT_ALERT_AFTER_SECONDS,
    "Uptime::Constants" => :RAW_RETENTION_DAYS,
    "Vulnerabilities::Constants" => :OSV_BATCH_SIZE,
    "Workload::Constants" => :DUE_SOON_THRESHOLD
  }.each do |nome, costante|
    it "#{nome} esiste e porta le costanti del suo dominio" do
      expect(Object.const_defined?(nome)).to be(true), "#{nome} non esiste: il dominio non ha il suo file."
      expect(nome.constantize.const_defined?(costante, false)).to be(true),
                                                                  "#{nome} non definisce #{costante}."
    end
  end

  # La rete che rende innocuo lo spostamento: un riferimento rimasto indietro non solleva finché
  # qualcuno non passa da quella riga — e una riga di view o di rake task non la esegue nessuna
  # prova. Qui si leggono TUTTI i riferimenti scritti nel repository, codice, pagine e note
  # comprese, e si controlla che ognuno punti a una costante che il file generale definisce ancora.
  it "nessun riferimento al file generale punta a una costante spostata" do
    sorgenti = Dir[Rails.root.join("{app,lib,config,spec,db}/**/*.{rb,rake,erb,js,yml,md}")]
      .select { |percorso| File.file?(percorso) }
    orfani = sorgenti.flat_map { |percorso|
      File.read(percorso).scrub.scan(/App::Constants::([A-Z][A-Z0-9_]*)/).flatten.uniq.filter_map { |nome|
        "#{Pathname(percorso).relative_path_from(Rails.root)} → #{nome}" unless costanti_generali.include?(nome)
      }
    }.sort

    expect(orfani).to be_empty,
                      "Questi riferimenti puntano a costanti che il file generale non ha più: " \
                      "#{orfani.join(', ')}. Vanno riscritti col nome del dominio."
  end

  # La trappola vista in CYRA-742: una parte annidata che porta il nome di qualcosa che esiste già al
  # primo livello lo OSCURA dentro tutto quel namespace. Qui il nome nuovo è `Constants`, ripetuto in
  # sedici namespace: se un giorno nascesse un `Constants` di primo livello, ogni riferimento nudo
  # dentro quei domini smetterebbe di risolvere dove risolveva prima.
  it "nessun dominio oscura un nome di primo livello" do
    radice = Rails.root.join("app/constants")
    collisioni = Dir[radice.join("**/*.rb")].sort.flat_map { |file|
      pezzi = Pathname(file).relative_path_from(radice).to_s.delete_suffix(".rb").split("/")
      pezzi.drop(1).filter_map { |pezzo|
        nome = pezzo.camelize
        "#{pezzi.join('/')}.rb → #{nome}" if Object.const_defined?(nome, false)
      }
    }

    expect(collisioni).to be_empty,
                          "Queste parti oscurano un nome di primo livello: #{collisioni.join(', ')}."
  end

  # L'altra faccia della stessa trappola, e questa è successa: `Monitoring::Constants` scritto dentro
  # `Member::Monitoring::MetricGroupsController` NON risolve al dominio. Ruby cerca il nome nei moduli
  # che avvolgono la riga, e `Member` definisce già `Monitoring`: la costante letta è
  # `Member::Monitoring::Constants`, che non esiste — «uninitialized constant», in una pagina sola,
  # solo quando qualcuno la apre. Dove il nome del dominio è anche il nome di una parte annidata, il
  # riferimento parte dalla radice (`::Monitoring::Constants`).
  it "un riferimento dentro un namespace omonimo parte dalla radice" do
    domini = Dir[Rails.root.join("app/constants/*/constants.rb")].map { |file| File.basename(File.dirname(file)).camelize }
    ambigui = Dir[Rails.root.join("{app,lib}/**/*.rb")].sort.flat_map { |percorso|
      testo = File.read(percorso).scrub
      scope = testo.scan(/^\s*(?:module|class)\s+([A-Z][\w:]*)/).flatten.flat_map { |aperto| aperto.split("::") }
      next [] if scope.empty?

      # Il `(?<!:)` scarta i riferimenti già ancorati alla radice: quelli non hanno il problema.
      testo.scan(/(?<![:\w])([A-Z]\w*)::Constants::/).flatten.uniq.select { |dominio| domini.include?(dominio) }
        .flat_map { |dominio|
          (1..scope.size).filter_map { |quanti|
            prefisso = scope.first(quanti).join("::")
            next if prefisso == dominio

            "#{Pathname(percorso).relative_path_from(Rails.root)} → #{dominio}" if Object.const_defined?("#{prefisso}::#{dominio}")
          }
        }
    }.uniq

    expect(ambigui).to be_empty,
                      "Qui il nome del dominio risolve su una parte annidata, non sul dominio: " \
                      "#{ambigui.join(', ')}. Vanno scritti con i due punti iniziali."
  end

  # I valori non cambiano: questo è un riordino, non una taratura. Un campione per dominio, scelto
  # fra quelli che una modifica distratta romperebbe in produzione senza far fallire nient'altro.
  it "i valori spostati restano quelli di prima" do
    expect(Accounts::Constants::OTP_MAX_ATTEMPTS).to eq(5)
    expect(Agents::Constants::PHASE_REVIEW_LIMIT).to eq(2)
    expect(Analytics::Constants::RETENTION_DEFAULT_DAYS).to eq(365)
    expect(Errors::Constants::RETENTION_DEFAULT_DAYS).to eq(30)
    expect(Logs::Constants::RETENTION_DEFAULT_DAYS).to eq(14)
    expect(Metrics::Constants::RETENTION_DEFAULT_DAYS).to eq(30)
    expect(Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT).to eq(5_000)
    expect(Servers::Constants::STALE_AFTER_SECONDS).to eq(180)
    expect(Ticketing::Constants::COMMENT_MAX_CHARS).to eq(240)
    expect(Uptime::Constants::RETENTION_DEFAULT_DAYS).to eq(730)
  end
end
