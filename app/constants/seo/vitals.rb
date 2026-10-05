# frozen_string_literal: true

module Seo
  # Le soglie dei Core Web Vitals e il vocabolario con cui si leggono (CYRA-537).
  #
  # Stanno QUI e in nessun altro posto: sono i numeri con cui Google decide se un sito è veloce, e
  # due schermate che li applicassero ciascuna per conto proprio darebbero due giudizi diversi sullo
  # stesso numero. Chi legge non avrebbe modo di capire quale dei due credere.
  #
  # I valori sono quelli ufficiali (web.dev), tutti misurati al **75° percentile** dei caricamenti,
  # separatamente per telefono e per computer: un p50 direbbe com'è andata alla metà più fortunata
  # degli utenti, che è la domanda sbagliata. `spec/models/seo/vitals_spec.rb` li presidia.
  module Vitals
    # Le tre metriche che Google usa per il posizionamento, più le due di supporto che spiegano le
    # prime. L'ordine è quello con cui si leggono in pagina.
    METRICS = %w[lcp inp cls ttfb fcp].freeze

    # I tre esiti. `good` non è "a posto per sempre": è "sotto la soglia adesso".
    RATINGS = %i[good needs_improvement poor].freeze

    # Il CLS è adimensionale (uno spostamento relativo), tutto il resto è in millisecondi.
    UNITLESS = %w[cls].freeze

    # [buono fino a, da migliorare fino a] — oltre il secondo valore è scarso.
    THRESHOLDS = {
      "lcp" => [ 2_500, 4_000 ],
      "inp" => [ 200, 500 ],
      "cls" => [ 0.1, 0.25 ],
      "ttfb" => [ 800, 1_800 ],
      "fcp" => [ 1_800, 3_000 ]
    }.freeze

    # Il punteggio di Lighthouse (0..100) ha le sue soglie, dichiarate da Google sulla pagina di
    # PageSpeed Insights: 90 e sopra è buono, sotto 50 è scarso.
    SCORE_THRESHOLDS = [ 50, 90 ].freeze

    # Sotto questo numero di misure un percentile non è un percentile: è il caso peggiore di una
    # manciata di visite, e mostrarlo come se fosse una misura sarebbe un numero inventato.
    MIN_SAMPLES = 50

    # La finestra su cui si legge il campo. Ventotto giorni è quella che usa Google per i suoi dati:
    # due finestre diverse affiancate nella stessa pagina risponderebbero a due domande diverse
    # dando l'impressione di rispondere alla stessa.
    FIELD_WINDOW_DAYS = 28

    # Il percentile. Non è configurabile: cambiarlo renderebbe i nostri numeri incomparabili con
    # quelli di Google, che è l'unico motivo per cui li mettiamo nella stessa pagina.
    PERCENTILE = 75

    module_function

    def known?(metric) = METRICS.include?(metric.to_s)

    def unitless?(metric) = UNITLESS.include?(metric.to_s)

    # L'esito di una misura, o nil se la metrica è ignota o il valore non c'è. Mai un esito di
    # comodo: una misura che non abbiamo non è "buona".
    def rating(metric, value)
      return nil if value.nil?

      thresholds = THRESHOLDS[metric.to_s]
      return nil if thresholds.nil?

      good, improvable = thresholds
      return :good if value <= good
      return :needs_improvement if value <= improvable

      :poor
    end

    # L'esito di un punteggio Lighthouse (0..100). `nil` resta `nil`: Google restituisce un punteggio
    # nullo quando non è riuscito a calcolarlo, e trattarlo come zero dipingerebbe di rosso un sito
    # che nessuno ha misurato.
    def score_rating(score)
      return nil if score.nil?

      poor, good = SCORE_THRESHOLDS
      return :poor if score < poor
      return :needs_improvement if score < good

      :good
    end
  end
end
