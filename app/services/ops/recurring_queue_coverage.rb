# frozen_string_literal: true

module Ops
  # I giri di config/recurring.yml finiscono su code che qualcuno serve davvero? Quarto controllo del
  # motore dei job, accanto a Ops::WorkerLiveness (i processi battono), Ops::QueueThroughput (la coda
  # smaltisce) e Ops::RecurringSchedule (lo Scheduler accoda). Quelli tre guardano il RUNTIME; questo
  # guarda la CONFIGURAZIONE, ed è l'unico che può accorgersi di un guasto che non produce errori.
  #
  # Perché serve (CYRA-785). Un giro accodato su una coda che nessun pool serve non solleva niente:
  # la riga entra in solid_queue_ready_executions e ci resta per sempre. Nessun errore, nessun job
  # fallito, nessun avviso — l'unico sintomo è che il giro non gira, e quello si nota solo se qualcuno
  # va a cercare il suo effetto.
  #
  # LA TRAPPOLA, che è già scattata. Un task scritto con `command:` invece che con `class:` NON gira
  # su "default": Solid Queue lo avvolge in SolidQueue::RecurringJob, che ha
  # `queue_as :solid_queue_recurring` scritto nel codice della gemma (app/jobs/solid_queue/
  # recurring_job.rb). `queue:` in recurring.yml è l'unico modo di spostarlo. Fino a CYRA-714
  # `clear_solid_queue_finished_jobs` non ce l'aveva: la potatura oraria dei job finiti non ha girato
  # dal 2026-08-07 al 2026-09-02, lasciando 628 job fermi che nessuno avrebbe mai smaltito.
  #
  # La domanda su quale coda finisca un task NON la ricostruiamo noi: la si fa a Solid Queue, con la
  # stessa API che usa il supervisor (RecurringTask.from_configuration, Worker#queues). È la lezione
  # di spec/config/queue_yml_spec.rb — un controllo che si ricostruisce da sé la risposta può solo
  # confermare la propria credenza, e qui la credenza sbagliata è precisamente il difetto.
  class RecurringQueueCoverage
    # Il rilievo che finisce nell'error tracking. Una classe propria e non un RuntimeError: così il
    # raggruppamento lo tiene separato dal resto e si vede a colpo d'occhio di cosa si tratta.
    UncoveredQueue = Class.new(StandardError)

    # Quando la coda di un giro non è calcolabile (una `queue_as { … }` che solleva). Segnalarla come
    # scoperta è la scelta prudente: chiede a un umano di guardarla, invece di far cadere la guardia
    # intera o di dichiararla coperta senza saperlo.
    UNKNOWN_QUEUE = "(non calcolabile)"

    class << self
      # Le code servite dai pool di worker, lette dalla configurazione già interpretata da Solid Queue
      # e non dal file: se un domani cambia la forma accettata in queue.yml, questo controllo la segue
      # senza doverla reimparare.
      #
      # `configured_processes` restituisce delle Struct(kind, attributes), non dei Worker: costruirli
      # davvero con `instantiate` avvierebbe pool e thread solo per leggerne un attributo.
      #
      # I nomi si prendono COSÌ COME SONO, senza spezzarli sulla virgola. `queues: "alerts,uptime"`
      # non sono due code: per Solid Queue è UNA coda che si chiama letteralmente "alerts,uptime" e
      # che non esiste, ed è il guasto che ha fermato tutti i job in produzione per due giorni. Se lo
      # spezzassimo qui, questo controllo direbbe che alerts e uptime sono servite mentre nessuno le
      # serve: un falso negativo proprio nel caso peggiore. Meglio dichiararle scoperte — perché lo
      # sono davvero.
      def worker_queues
        SolidQueue::Configuration.new
                                 .configured_processes
                                 .select { |process| process.kind.to_sym == :worker }
                                 .flat_map { |process| Array(process.attributes[:queues]).map(&:to_s) }
                                 .uniq
      end

      # La coda su cui un task finirebbe DAVVERO. `queue:` esplicito vince; altrimenti decide la
      # classe del job, che per i task `command:` è SolidQueue::RecurringTask.default_job_class.
      #
      # `new(*args).queue_name` e non `.queue_name`: con `queue_as { … }` la coda è un blocco valutato
      # sull'istanza, quindi leggere l'attributo di classe restituirebbe il blocco invece del nome, e
      # istanziare senza argomenti lo valuterebbe su un job diverso da quello che verrà accodato
      # davvero. Gli `args:` del task sono gli stessi che passa Solid Queue quando lo accoda.
      def queue_for(task)
        options = task.symbolize_keys
        explicit = options[:queue].presence
        return explicit.to_s if explicit

        job_class_for(options).new(*arguments_with_kwargs(options)).queue_name
      rescue StandardError
        UNKNOWN_QUEUE
      end

      # La coda `queue` è servita da qualcuno? NON è un confronto fra stringhe: Solid Queue accetta
      # `*` (tutte le code) e `prefisso*` (quelle che iniziano così), e trattarli alla lettera
      # dichiarerebbe scoperte code che invece qualcuno serve. Con Ops::OrphanRecurringJobs dietro,
      # quell'errore non è cosmetico: renderebbe cancellabili i job di una coda viva.
      #
      # Le code in pausa restano fuori dal conto di proposito: una pausa è una scelta temporanea, e
      # trattarla come una coda scoperta farebbe gridare al guasto ogni volta che se ne mette una in
      # attesa apposta.
      def covered?(queue)
        selectors = worker_queues
        return true if selectors.include?("*")

        selectors.any? do |selector|
          if selector.end_with?("*")
            queue.to_s.start_with?(selector.delete_suffix("*"))
          else
            selector == queue.to_s
          end
        end
      end

      # I giri che finiscono su una coda che nessun pool serve, come [{ key:, queue: }].
      # `tasks:` è iniettabile per i test; di default è la configurazione di produzione, che è la sola
      # in cui i giri ricorrenti girano davvero (staging incluso: gira con RAILS_ENV=production).
      def uncovered(tasks: production_tasks)
        tasks.filter_map do |key, options|
          queue = queue_for(options)
          { key: key.to_s, queue: } unless covered?(queue)
        end
      end

      # I giri dichiarati per la produzione, letti dal file com'è (ERB incluso, come fa Solid Queue).
      def production_tasks
        raw = ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result
        YAML.safe_load(raw, aliases: true).fetch("production", {})
      end

      private

      # Solid Queue converte l'ULTIMO hash degli `args` in keyword arguments
      # (`RecurringTask#arguments_with_kwargs`). Senza la stessa conversione un job che accetta
      # kwargs riceverebbe un hash posizionale: coda calcolata su un job diverso da quello che verrà
      # accodato davvero, o ArgumentError.
      def arguments_with_kwargs(options)
        args = Array.wrap(options[:args])
        return args unless args.last.is_a?(Hash)

        args[0...-1] + [ Hash.ruby2_keywords_hash(args.last) ]
      end

      # `SolidQueue::RecurringTask#job_class` è privato nella gemma, quindi la risoluzione la
      # rifacciamo qui — ma sulla stessa `default_job_class` che usa lei, non su una costante nostra:
      # se un domani la gemma cambia il wrapper dei task `command:`, questo controllo la segue.
      def job_class_for(options)
        name = options[:class].presence
        return SolidQueue::RecurringTask.default_job_class if name.blank?

        name.to_s.safe_constantize ||
          raise(ArgumentError, "giro ricorrente su una classe che non esiste: #{name}")
      end
    end
  end
end
