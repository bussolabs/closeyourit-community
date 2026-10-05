# frozen_string_literal: true

module Seo
  # CYRA-824 — il segnale che lo stato di un sito è cambiato, per chi ha la sua scheda aperta.
  # I nomi-stream vengono SOLO da Realtime::Streams (isolamento tenant nel nome).
  #
  # NON spedisce HTML, e non è una precauzione generica: la scheda mostra «Rilancia» e «Modifica»
  # solo a chi ha `seo.manage` sul progetto del sito, mentre per leggerla basta vedere il progetto.
  # Due persone davanti alla stessa pagina devono quindi riceverne due versioni diverse, e una
  # pagina renderizzata qui non saprebbe per chi è. Viaggia il solo «quel pezzo è vecchio»: ognuno
  # ri-chiede il riquadro con la propria sessione e il filtro lo rifà il controller.
  #
  # UN segnale per esito, mai uno per pagina visitata: un sito da cento pagine manderebbe cento
  # richieste identiche per un solo risultato. Il throttle di Realtime::ThrottledRefresh è per
  # stream, quindi coalesce già per sito — inizio e fine di uno stesso giro distano minuti e
  # restano due segnali distinti, che è esattamente quello che serve.
  module Broadcast
    # Il nome del riquadro bersaglio vive QUI, dove nasce il segnale, e la pagina lo legge da qui
    # (Member::Monitoring::SeoSitesController): in due posti diversi, un rinominio da un lato solo
    # manderebbe il segnale a un riquadro che non esiste più — e la scheda smetterebbe di
    # aggiornarsi in silenzio, senza nessun errore da nessuna parte.
    #
    # È lo STESSO nome sul riepilogo e sulla scheda velocità, di proposito: il segnale non sa quale
    # delle due chi guarda ha davanti, e ognuna ricarica il proprio indirizzo. L'intestazione coi
    # conteggi sta dentro il riquadro insieme ai risultati, così le due metà non possono contraddirsi
    # (la lezione di CYRA-498: i chip che dicono «0» sopra un elenco che ne mostra tre).
    LIVE_FRAME = "seo-site-live"

    module_function

    # NON solleva MAI verso chi chiama, e non è prudenza generica: i due call-site sono dentro il
    # `rescue StandardError` che marca il giro come fallito (Seo::AuditSite, Seo::MeasureLab). Un
    # guasto del trasporto — cable giù, cache irraggiungibile — risalendo da qui riscriverebbe un
    # controllo RIUSCITO come fallito, con il nome della classe d'errore al posto del motivo, e
    # lascerebbe sul sito un `last_error` che non è mai successo. In AuditSite andrebbe anche in
    # ricorsione: `fail_audit` richiama `finish`, che richiama questo.
    #
    # Il confine giusto è qui e non nei chiamanti: avvisare chi sta guardando è un accessorio della
    # LETTURA, e il suo guasto non può cambiare l'esito del lavoro che descrive. Chi non riceve il
    # segnale ricarica al giro di riconciliazione della pagina — resta indietro di qualche minuto,
    # non legge una bugia.
    def state(site)
      Realtime::ThrottledRefresh.call(Realtime::Streams.seo_site(site), frame: LIVE_FRAME)
    rescue StandardError => e
      Rails.logger.warn("Seo::Broadcast — #{e.class}: #{e.message}")
      nil
    end
  end
end
