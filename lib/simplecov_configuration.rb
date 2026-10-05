# frozen_string_literal: true

# Politica di calcolo della copertura (CYRA-551, CYRA-550).
#
# Questo file viene caricato in due mondi diversi: da `spec_helper` prima che Rails esista (quindi
# niente ActiveSupport qui dentro: `present?` e amici non sono ancora definiti) e dall'autoload di
# `lib/` quando le spec interrogano la politica. Le decisioni sono perciò funzioni pure su un hash
# d'ambiente: si possono verificare senza riconfigurare il SimpleCov del processo in corso, che è
# anche quello che sta misurando il run.
#
# CYRA-550 — configurare e avviare sono due passi separati, e stanno in due file diversi, perché da
# simplecov 1.0 `.simplecov` è un file di SOLA configurazione: `SimpleCov.start` chiamato lì dentro
# stampa una deprecazione e in una prossima versione non avvierà più niente. Quindi `.simplecov`
# chiama `configure!` e l'avvio lo fa `spec_helper` con `start!`, che è anche il primo file che
# rspec carica — prima di qualunque codice applicativo, com'è necessario perché il conteggio sia
# vero.
#
# Nessun `require` di simplecov in testa al file, di proposito: `spec_helper` include questa
# politica a OGNI run, anche quando la copertura è spenta, e caricare la gemma per poi non usarla è
# tempo regalato a ogni giro del ciclo rosso-verde. Le gemme si caricano quando servono davvero.
module SimplecovConfiguration
  # Basta una di queste per accendere la copertura. `CI` c'è perché i controlli automatici la usano
  # come gate e non impostano `COVERAGE`; `COVERAGE_ENFORCE` perché il job che collaziona gli shard
  # dichiara solo quella.
  ENABLING_VARIABLES = %w[COVERAGE CI COVERAGE_ENFORCE].freeze

  # Una variabile lasciata a vuoto o a zero è un no, non un sì: `COVERAGE=` dimenticato in una shell
  # rimetterebbe in conto il costo del report a ogni run senza che nessuno lo abbia chiesto.
  OFF_VALUES = [ "", "0", "false", "no", "off" ].freeze

  class << self
    def enabled?(env = ENV)
      ENABLING_VARIABLES.any? { |name| on?(env[name]) }
    end

    # I formatter costano: HTML rilegge e impagina ~37.000 righe tracciate, LCOV ne serializza
    # altrettante. Dentro uno shard quel lavoro è buttato — il template raccoglie soltanto
    # `coverage/.resultset.json` e il job `coverage` (rake coverage:collate) genera i report una
    # volta sola sul risultato unito. Il resultset grezzo viene scritto comunque: SimpleCov lo salva
    # in `SimpleCov.result`, prima e indipendentemente dai formatter.
    def formatters_for(env = ENV)
      return [] if shard?(env)

      load_simplecov!
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::LcovFormatter
      ]
    end

    # Ogni processo che misura deve avere un nome suo, o il merge dei resultset ne terrebbe uno
    # solo. Gli shard CI si presentano con TEST_SHARD; i processi della suite parallela locale con
    # TEST_ENV_NUMBER, che parallel_tests lascia a stringa vuota per il primo.
    def command_name_for(env = ENV)
      shard = env["TEST_SHARD"]
      return "rspec-shard-#{shard}" unless blank?(shard)

      parallel_process = env["TEST_ENV_NUMBER"]
      return nil if parallel_process.nil?

      "rspec-shard-#{blank?(parallel_process) ? 1 : parallel_process}"
    end

    # Applicata una volta sola per processo: la si chiama da due punti (`.simplecov`, che simplecov
    # carica da sé, e `start!`, che non può dare per scontato di essere passato di lì) e i filtri si
    # accumulano invece di sostituirsi.
    def apply(env = ENV)
      return if @applied

      @applied = true
      load_simplecov!

      SimpleCov::Formatter::LcovFormatter.config do |config|
        config.report_with_single_file = true
        config.single_report_path = "coverage/lcov.info"
      end

      SimpleCov.formatters = formatters_for(env)

      SimpleCov.configure do
        enable_coverage :branch
        primary_coverage :line
        skip %w[/spec/ /config/ /db/ /vendor/ /bin/]
        # Base class scaffold vuote (nessuna logica): escluse finché non acquisiscono codice,
        # poi rientrano col loro request/job/mailer spec. Vedi rules/tdd.md (no test del framework).
        skip %w[
          app/controllers/application_controller.rb
          app/jobs/application_job.rb
          app/mailers/application_mailer.rb
        ]
        # Questo file stesso (CYRA-667). Non e' una scorciatoia per alzare la percentuale: spec_helper
        # lo carica alla riga 30 e avvia SimpleCov alla 31, quindi le sue righe sono gia' state
        # interpretate quando la misura comincia e non potranno MAI risultare coperte. Lasciarlo dentro
        # significa tenere 143 righe a zero per costruzione, cioe' una tassa fissa sulla percentuale che
        # nessun test potra' mai togliere. Le sue funzioni sono pure e restano provabili: quello che non
        # e' misurabile e' la copertura DI QUESTO file, non il suo comportamento.
        skip %w[lib/simplecov_configuration.rb]
        # `cover` prende il posto della vecchia direttiva di tracking: include i file su disco che
        # nessun test ha caricato — un service mai chiamato deve pesare come zero, non sparire dal
        # conto — e in più restringe il report allo stesso insieme.
        cover "{app,lib}/**/*.rb"

        minimum_coverage(line: 90, branch: 90) if env["COVERAGE_ENFORCE"]
      end
    end

    # Punto di ingresso di `.simplecov`, che è un file di sola configurazione: decide e configura,
    # senza avviare niente. Fuori dai controlli automatici non fa nulla finché non gliela si chiede.
    def configure!(env = ENV)
      return unless enabled?(env)

      apply(env)
    end

    # Punto di ingresso di `spec_helper`: fa partire il tracking vero.
    #
    # `require "simplecov"` carica anche `.simplecov`, e quindi `configure!`. `apply` viene chiamata
    # lo stesso perché quel file lo cerca simplecov per conto suo risalendo da `SimpleCov.root`: se
    # non lo trovasse, il tracking partirebbe senza filtri e senza soglia e il gate direbbe di sì
    # senza aver guardato niente — che è esattamente il guasto da cui nasce CYRA-550.
    def start!(env = ENV)
      return unless enabled?(env)

      load_simplecov!
      apply(env)
      command_name = command_name_for(env)
      SimpleCov.command_name(command_name) if command_name
      SimpleCov.start "rails"
    end

    private

    def load_simplecov!
      require "simplecov"
      require "simplecov-lcov"
    end

    def shard?(env)
      !blank?(env["TEST_SHARD"])
    end

    def on?(value)
      !blank?(value) && !OFF_VALUES.include?(value.to_s.strip.downcase)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
